// 카메라 소스(mac-avcapture) 설정 도우미
//
// mac-avcapture의 High 프리셋은 iPad 내장 카메라에서 보통 1080p30이다. 캔버스(1080p60)에 맞추려면
// 수동 설정(use_preset=false)으로 형식과 fps를 직접 지정해야 하고, 형식은 플러그인이 쓰는 내부 표현
// (AVCaptureDeviceFormat+OBSListable의 obsPropertyListInternalRepresentation)으로 넘긴다.

@import AVFoundation;

#import "AVCaptureDeviceFormat+OBSListable.h"

#include "capture-format.h"

#include <media-io/frame-rate.h>
#include <util/bmem.h>

#include <math.h>

// plugin-properties.m의 iOS 장치 종류와 같게 둔다
static NSArray<AVCaptureDeviceType> *camera_device_types(void)
{
	return @[
		AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera,
		AVCaptureDeviceTypeBuiltInTelephotoCamera, AVCaptureDeviceTypeBuiltInTrueDepthCamera,
		AVCaptureDeviceTypeExternal
	];
}

char *capture_default_camera_id(void)
{
	AVCaptureDeviceDiscoverySession *discovery =
		[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:camera_device_types()
								       mediaType:AVMediaTypeVideo
									position:AVCaptureDevicePositionUnspecified];

	AVCaptureDevice *pick = nil;

	for (AVCaptureDevice *device in discovery.devices) {
		if ([device.deviceType isEqualToString:AVCaptureDeviceTypeExternal]) {
			pick = device;
			break;
		}
	}

	if (!pick) {
		pick = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
							  mediaType:AVMediaTypeVideo
							   position:AVCaptureDevicePositionBack];
	}

	if (!pick) {
		pick = discovery.devices.firstObject;
	}

	return pick ? bstrdup(pick.uniqueID.UTF8String) : NULL;
}

// 다른 소스가 쓰지 않는 카메라: 외부(UVC) → 후면 광각 → 전면 광각 → 나머지 순.
// 모두 쓰는 중이면 capture_default_camera_id와 같다.
char *capture_unused_camera_id(const char *const *used, size_t used_count)
{
	NSMutableSet<NSString *> *busy = [NSMutableSet set];
	for (size_t i = 0; i < used_count; i++) {
		if (used[i] && *used[i])
			[busy addObject:@(used[i])];
	}

	AVCaptureDeviceDiscoverySession *discovery =
		[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:camera_device_types()
								       mediaType:AVMediaTypeVideo
									position:AVCaptureDevicePositionUnspecified];

	for (int pass = 0; pass < 4; pass++) {
		for (AVCaptureDevice *device in discovery.devices) {
			if ([busy containsObject:device.uniqueID])
				continue;

			bool external = [device.deviceType isEqualToString:AVCaptureDeviceTypeExternal];
			bool wide = [device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera];
			bool match = pass == 0   ? external
				     : pass == 1 ? wide && device.position == AVCaptureDevicePositionBack
				     : pass == 2 ? wide && device.position == AVCaptureDevicePositionFront
						 : true;
			if (match)
				return bstrdup(device.uniqueID.UTF8String);
		}
	}

	return capture_default_camera_id();
}

char *capture_camera_list(void)
{
	AVCaptureDeviceDiscoverySession *discovery =
		[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:camera_device_types()
								       mediaType:AVMediaTypeVideo
									position:AVCaptureDevicePositionUnspecified];

	NSMutableString *lines = [NSMutableString string];
	for (AVCaptureDevice *device in discovery.devices)
		[lines appendFormat:@"%@\t%@\t1\n", device.uniqueID, device.localizedName];

	return bstrdup(lines.UTF8String);
}

static bool is_nv12(FourCharCode subtype)
{
	return subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
	       subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

// mac-avcapture가 libobs로 넘길 수 있는 픽셀 형식 (OBSAVCapture formatFromSubtype:)
static bool is_supported(FourCharCode subtype)
{
	switch (subtype) {
	case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
	case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
	case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
	case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
	case kCVPixelFormatType_422YpCbCr8:
	case kCVPixelFormatType_422YpCbCr8_yuvs:
	case kCVPixelFormatType_32BGRA:
		return true;
	default:
		return false;
	}
}

static bool supports_fps(AVCaptureDeviceFormat *format, double fps)
{
	for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
		if (range.minFrameRate <= fps + 0.01 && fps - 0.01 <= range.maxFrameRate)
			return true;
	}
	return false;
}

static double max_fps(AVCaptureDeviceFormat *format)
{
	double result = 0.0;
	for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges)
		result = fmax(result, range.maxFrameRate);
	return result;
}

// 고르는 순서
// 1. 캔버스와 같은 해상도, 목표 fps 가능, NV12
// 2. 캔버스와 같은 해상도, 목표 fps 가능
// 3. 캔버스 이하 해상도 중 목표 fps가 가능한 가장 큰 것
// 4. 캔버스와 같은 해상도 중 fps가 가장 높은 것 (fps는 그 형식의 최대값)
static AVCaptureDeviceFormat *pick_format(AVCaptureDevice *device, uint32_t width, uint32_t height, double fps,
					  double *out_fps)
{
	AVCaptureDeviceFormat *exact_nv12 = nil;
	AVCaptureDeviceFormat *exact = nil;
	AVCaptureDeviceFormat *smaller = nil;
	int64_t smaller_area = 0;
	AVCaptureDeviceFormat *exact_slow = nil;
	double exact_slow_fps = 0.0;

	for (AVCaptureDeviceFormat *format in device.formats) {
		FourCharCode subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription);
		if (!is_supported(subtype))
			continue;

		CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
		bool same_size = (uint32_t)size.width == width && (uint32_t)size.height == height;
		bool fps_ok = supports_fps(format, fps);

		if (same_size && fps_ok && is_nv12(subtype) && !exact_nv12)
			exact_nv12 = format;
		if (same_size && fps_ok && !exact)
			exact = format;

		int64_t area = (int64_t)size.width * size.height;
		if (fps_ok && (uint32_t)size.width <= width && (uint32_t)size.height <= height && area > smaller_area) {
			smaller = format;
			smaller_area = area;
		}

		if (same_size && max_fps(format) > exact_slow_fps) {
			exact_slow = format;
			exact_slow_fps = max_fps(format);
		}
	}

	*out_fps = fps;
	if (exact_nv12)
		return exact_nv12;
	if (exact)
		return exact;
	if (smaller)
		return smaller;

	*out_fps = floor(exact_slow_fps);
	return exact_slow;
}

void capture_configure_camera(obs_data_t *settings, const char *device_id, uint32_t width, uint32_t height,
			      uint32_t fps)
{
	obs_data_set_string(settings, "device", device_id ? device_id : "");

	AVCaptureDevice *device = (device_id && *device_id) ? [AVCaptureDevice deviceWithUniqueID:@(device_id)] : nil;
	if (!device) {
		blog(LOG_INFO, "[app] camera: no device");
		return;
	}

	double format_fps = fps;
	AVCaptureDeviceFormat *format = pick_format(device, width, height, fps, &format_fps);

	if (format && format_fps >= 1.0) {
		struct media_frames_per_second rate = {.numerator = (uint32_t)llround(format_fps), .denominator = 1};

		obs_data_set_bool(settings, "use_preset", false);
		obs_data_set_string(settings, "supported_format", format.obsPropertyListInternalRepresentation.UTF8String);
		obs_data_set_frames_per_second(settings, "frame_rate", rate, NULL);

		blog(LOG_INFO, "[app] camera '%s': %s @ %u fps", device.localizedName.UTF8String,
		     format.obsPropertyListDescription.UTF8String, rate.numerator);
	} else {
		obs_data_set_bool(settings, "use_preset", true);
		obs_data_set_string(settings, "preset", AVCaptureSessionPresetHigh.UTF8String);

		blog(LOG_INFO, "[app] camera '%s': no format for %ux%u, using the High preset",
		     device.localizedName.UTF8String, width, height);
	}
}
