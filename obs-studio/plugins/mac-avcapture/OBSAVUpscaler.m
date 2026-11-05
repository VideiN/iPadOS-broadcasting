//
//  OBSAVUpscaler.m
//  mac-avcapture (iOS port)
//
//  Modes, all from the capture frame to a 1440p BGRA frame that goes to libobs like any other camera frame:
//    vt_transfer       VTPixelTransferSession scaling
//    mps_bilinear      Metal Performance Shaders
//    mps_lanczos       Metal Performance Shaders
//    ci_lanczos        Core Image
//    metalfx_spatial   MetalFX spatial scaler (not in the simulator)
//    vt_lowlatency_sr  VTLowLatencySuperResolutionScaler, iOS 26+, then down to 1440p (not in the simulator)
//    vt_sr_image       VTSuperResolutionScaler, iOS 26+, then down to 1440p (not in the simulator). The "video" input of
//                      this processor stops at 1440 wide on iOS, so 1080p can only go through its "image" input.
//

#import "OBSAVUpscaler.h"

#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <VideoToolbox/VideoToolbox.h>

#include <TargetConditionals.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <obs.h>
#include <util/platform.h>

#if !TARGET_OS_SIMULATOR
#define OBS_UPSCALE_DEVICE_ONLY 1
#import <MetalFX/MetalFX.h>
#if __has_include(<VideoToolbox/VTFrameProcessor.h>)
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessorFrame.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencySuperResolutionScaler.h>
#import <VideoToolbox/VTFrameProcessor_SuperResolutionScaler.h>
#endif
#endif

static NSString *const kModeTransfer = @"vt_transfer";
static NSString *const kModeMPSBilinear = @"mps_bilinear";
static NSString *const kModeMPSLanczos = @"mps_lanczos";
static NSString *const kModeCILanczos = @"ci_lanczos";
static NSString *const kModeMetalFX = @"metalfx_spatial";
static NSString *const kModeLowLatencySR = @"vt_lowlatency_sr";
static NSString *const kModeImageSR = @"vt_sr_image";

typedef NS_ENUM(NSInteger, OBSUpscaleSessionState) {
    OBSUpscaleSessionNone,
    OBSUpscaleSessionLoading,
    OBSUpscaleSessionReady,
    OBSUpscaleSessionFailed,
};

static NSString *const kOpaqueCopyShader = @"#include <metal_stdlib>\n"
                                            "using namespace metal;\n"
                                            "kernel void opaque_copy(texture2d<float, access::read> source [[texture(0)]],\n"
                                            "                        texture2d<float, access::write> target [[texture(1)]],\n"
                                            "                        uint2 position [[thread_position_in_grid]]) {\n"
                                            "    target.write(float4(source.read(position).rgb, 1.0), position);\n"
                                            "}\n";

@interface OBSAVUpscaler ()

@property (atomic, readwrite, copy) NSString *status;

/// Session of the VT processors. Written by the setup queue, read by the capture queue.
@property (atomic) OBSUpscaleSessionState sessionState;
@property (atomic, strong, nullable) id sessionProcessor;
@property (atomic, strong, nullable) id sessionConfiguration;
@property (atomic) size_t sessionWidth;
@property (atomic) size_t sessionHeight;
@property (atomic) float sessionFactor;
@property (atomic, copy, nullable) NSString *sessionMode;
@property (atomic, copy, nullable) NSString *sessionFailure;
@property (atomic, copy, nullable) NSString *sessionProgress;

#ifdef OBS_UPSCALE_DEVICE_ONLY
- (void)startLowLatencySessionWidth:(size_t)width height:(size_t)height API_AVAILABLE(ios(26.0));
- (void)startImageSRSessionWidth:(size_t)width height:(size_t)height API_AVAILABLE(ios(26.0));
- (BOOL)prepareSessionForMode:(NSString *)mode width:(size_t)width height:(size_t)height API_AVAILABLE(ios(26.0));
- (nullable NSString *)runProcessorFrom:(CVPixelBufferRef)source
                                   mode:(NSString *)mode
                                     to:(CVPixelBufferRef)output API_AVAILABLE(ios(26.0));
#endif

@end

@implementation OBSAVUpscaler {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    CVMetalTextureCacheRef _textureCache;
    VTPixelTransferSessionRef _transfer;
    NSMutableDictionary<NSString *, id> *_pools;
    CIContext *_ciContext;
    MPSImageBilinearScale *_mpsBilinear;
    MPSImageLanczosScale *_mpsLanczos;
    id<MTLComputePipelineState> _opaqueCopy;
    dispatch_queue_t _setupQueue;

#ifdef OBS_UPSCALE_DEVICE_ONLY
    id<MTLFXSpatialScaler> _metalFX;
    id<MTLTexture> _metalFXOutput;
    size_t _metalFXWidth;
    size_t _metalFXHeight;
#endif

    NSString *_currentMode;
    NSString *_loggedFailure;
    int64_t _frameCounter;

    uint64_t _windowStart;
    uint32_t _windowFrames;
    uint64_t _windowTotalNs;
    uint64_t _windowMaxNs;
    uint32_t _windowLogCounter;
    NSString *_sizeText;
}

+ (NSArray<NSString *> *)modes
{
    return @[kModeTransfer, kModeMPSBilinear, kModeMPSLanczos, kModeCILanczos, kModeMetalFX, kModeLowLatencySR, kModeImageSR];
}

+ (NSString *)labelForMode:(NSString *)mode
{
    NSDictionary<NSString *, NSString *> *labels = @{
        kModeTransfer: @"VT 픽셀 전송",
        kModeMPSBilinear: @"MPS 쌍선형",
        kModeMPSLanczos: @"MPS Lanczos",
        kModeCILanczos: @"Core Image Lanczos",
        kModeMetalFX: @"MetalFX 공간",
        kModeLowLatencySR: @"VT 저지연 초해상도 (iOS 26+)",
        kModeImageSR: @"VT 초해상도, 이미지 (iOS 26+, 모델 다운로드)",
    };
    return labels[mode] ?: mode;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _device = MTLCreateSystemDefaultDevice();
        _queue = [_device newCommandQueue];
        _pools = [NSMutableDictionary dictionary];
        _setupQueue = dispatch_queue_create("obs.avcapture.upscale.setup", DISPATCH_QUEUE_SERIAL);
        _status = @"";

        if (_device) {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache);
        }
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transfer);
        if (_transfer) {
            VTSessionSetProperty(_transfer, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal);
        }
    }
    return self;
}

- (void)dealloc
{
    [self endSession];
    if (_transfer) {
        VTPixelTransferSessionInvalidate(_transfer);
        CFRelease(_transfer);
    }
    if (_textureCache) {
        CFRelease(_textureCache);
    }
}

#pragma mark - Buffers and textures

/// `attributes` are a frame processor's requirements for the buffer, nil otherwise
- (CVPixelBufferRef)createBufferWidth:(size_t)width
                               height:(size_t)height
                               format:(OSType)format
                           attributes:(nullable NSDictionary *)attributes
{
    NSString *key = [NSString stringWithFormat:@"%zux%zu-%u-%d", width, height, (unsigned) format, attributes != nil];
    CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef) _pools[key];

    if (!pool) {
        NSMutableDictionary *merged = attributes ? [attributes mutableCopy] : [NSMutableDictionary dictionary];
        merged[(id) kCVPixelBufferWidthKey] = @(width);
        merged[(id) kCVPixelBufferHeightKey] = @(height);
        merged[(id) kCVPixelBufferPixelFormatTypeKey] = @(format);
        merged[(id) kCVPixelBufferMetalCompatibilityKey] = @YES;
        if (!merged[(id) kCVPixelBufferIOSurfacePropertiesKey]) {
            merged[(id) kCVPixelBufferIOSurfacePropertiesKey] = @{};
        }

        CVPixelBufferPoolRef created = NULL;
        CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef) merged, &created);
        if (result != kCVReturnSuccess || !created) {
            blog(LOG_WARNING, "[upscale] no buffer pool for %s (%d)", key.UTF8String, result);
            return NULL;
        }
        _pools[key] = (__bridge_transfer id) created;
        pool = created;
    }

    CVPixelBufferRef buffer = NULL;
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer);
    return buffer;
}

- (BOOL)transferFrom:(CVPixelBufferRef)source to:(CVPixelBufferRef)target
{
    if (!_transfer) {
        return NO;
    }
    OSStatus result = VTPixelTransferSessionTransferImage(_transfer, source, target);
    if (result != noErr) {
        blog(LOG_WARNING, "[upscale] pixel transfer failed (%d)", (int) result);
    }
    return result == noErr;
}

/// The caller keeps `holder` until the GPU is done with the texture
- (nullable id<MTLTexture>)textureFor:(CVPixelBufferRef)buffer
                                usage:(MTLTextureUsage)usage
                               holder:(CVMetalTextureRef *)holder
{
    if (!_textureCache) {
        return nil;
    }
    NSDictionary *attributes = @{(id) kCVMetalTextureUsage: @(usage)};
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _textureCache, buffer, (__bridge CFDictionaryRef) attributes, MTLPixelFormatBGRA8Unorm,
        CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, holder);
    if (result != kCVReturnSuccess || !*holder) {
        blog(LOG_WARNING, "[upscale] no texture for the frame (%d)", result);
        return nil;
    }
    return CVMetalTextureGetTexture(*holder);
}

/// BGRA at the source's size, for the modes that work on RGB
- (nullable CVPixelBufferRef)createBGRAFrom:(CVPixelBufferRef)source
{
    if (CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA) {
        return CVPixelBufferRetain(source);
    }
    CVPixelBufferRef bgra = [self createBufferWidth:CVPixelBufferGetWidth(source)
                                             height:CVPixelBufferGetHeight(source)
                                             format:kCVPixelFormatType_32BGRA
                                         attributes:nil];
    if (bgra && ![self transferFrom:source to:bgra]) {
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    return bgra;
}

#pragma mark - Modes

- (BOOL)runMPS:(MPSImageScale *)scaler from:(CVPixelBufferRef)bgra to:(CVPixelBufferRef)output
{
    CVMetalTextureRef sourceHolder = NULL;
    CVMetalTextureRef targetHolder = NULL;
    const MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    id<MTLTexture> source = [self textureFor:bgra usage:usage holder:&sourceHolder];
    id<MTLTexture> target = [self textureFor:output usage:usage holder:&targetHolder];

    BOOL ok = NO;
    if (source && target) {
        id<MTLCommandBuffer> commands = [_queue commandBuffer];
        [scaler encodeToCommandBuffer:commands sourceTexture:source destinationTexture:target];
        [commands commit];
        [commands waitUntilCompleted];
        ok = commands.status == MTLCommandBufferStatusCompleted;
    }
    if (sourceHolder) {
        CFRelease(sourceHolder);
    }
    if (targetHolder) {
        CFRelease(targetHolder);
    }
    return ok;
}

- (BOOL)runCILanczosFrom:(CVPixelBufferRef)bgra to:(CVPixelBufferRef)output
{
    if (!_ciContext) {
        NSDictionary *options = @{kCIContextWorkingColorSpace: [NSNull null], kCIContextOutputColorSpace: [NSNull null]};
        _ciContext = _device ? [CIContext contextWithMTLDevice:_device options:options]
                             : [CIContext contextWithOptions:options];
    }
    const size_t width = CVPixelBufferGetWidth(output);
    const size_t height = CVPixelBufferGetHeight(output);
    const double scale = (double) height / (double) CVPixelBufferGetHeight(bgra);
    const double aspect = ((double) width / (double) CVPixelBufferGetWidth(bgra)) / scale;

    // Clamped so that the filter does not fade to transparent at the edges
    CIImage *image = [[CIImage imageWithCVPixelBuffer:bgra options:@{kCIImageColorSpace: [NSNull null]}] imageByClampingToExtent];
    CIFilter *filter = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    [filter setValue:image forKey:kCIInputImageKey];
    [filter setValue:@(scale) forKey:kCIInputScaleKey];
    [filter setValue:@(aspect) forKey:kCIInputAspectRatioKey];
    if (!filter.outputImage) {
        return NO;
    }
    [_ciContext render:filter.outputImage
        toCVPixelBuffer:output
                 bounds:CGRectMake(0, 0, width, height)
             colorSpace:NULL];
    return YES;
}

#ifdef OBS_UPSCALE_DEVICE_ONLY

- (nullable NSString *)runMetalFXFrom:(CVPixelBufferRef)bgra to:(CVPixelBufferRef)output
{
    if (![MTLFXSpatialScalerDescriptor supportsDevice:_device]) {
        return @"이 GPU는 MetalFX 공간 스케일러를 지원하지 않음";
    }

    const size_t inputWidth = CVPixelBufferGetWidth(bgra);
    const size_t inputHeight = CVPixelBufferGetHeight(bgra);
    const size_t outputWidth = CVPixelBufferGetWidth(output);
    const size_t outputHeight = CVPixelBufferGetHeight(output);

    if (!_metalFX || _metalFXWidth != inputWidth || _metalFXHeight != inputHeight) {
        MTLFXSpatialScalerDescriptor *descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
        descriptor.inputWidth = inputWidth;
        descriptor.inputHeight = inputHeight;
        descriptor.outputWidth = outputWidth;
        descriptor.outputHeight = outputHeight;
        descriptor.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        _metalFX = [descriptor newSpatialScalerWithDevice:_device];
        if (!_metalFX) {
            return @"MetalFX 스케일러를 만들지 못함";
        }

        MTLTextureDescriptor *textureDescriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:outputWidth
                                                              height:outputHeight
                                                           mipmapped:NO];
        textureDescriptor.storageMode = MTLStorageModePrivate;
        textureDescriptor.usage = _metalFX.outputTextureUsage | MTLTextureUsageShaderRead;
        _metalFXOutput = [_device newTextureWithDescriptor:textureDescriptor];
        _metalFXWidth = inputWidth;
        _metalFXHeight = inputHeight;
    }

    if (!_opaqueCopy) {
        NSError *error = nil;
        id<MTLLibrary> library = [_device newLibraryWithSource:kOpaqueCopyShader options:nil error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"opaque_copy"];
        _opaqueCopy = function ? [_device newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!_opaqueCopy) {
            return [NSString stringWithFormat:@"알파 복사 셰이더 실패: %@", error.localizedDescription];
        }
    }

    CVMetalTextureRef sourceHolder = NULL;
    CVMetalTextureRef targetHolder = NULL;
    id<MTLTexture> source = [self textureFor:bgra usage:_metalFX.colorTextureUsage | MTLTextureUsageShaderRead holder:&sourceHolder];
    id<MTLTexture> target = [self textureFor:output usage:MTLTextureUsageShaderWrite holder:&targetHolder];

    NSString *failure = nil;
    if (source && target && _metalFXOutput) {
        id<MTLCommandBuffer> commands = [_queue commandBuffer];
        _metalFX.colorTexture = source;
        _metalFX.inputContentWidth = inputWidth;
        _metalFX.inputContentHeight = inputHeight;
        _metalFX.outputTexture = _metalFXOutput;
        [_metalFX encodeToCommandBuffer:commands];

        // The scaler's alpha is undefined and libobs would blend with it. Also moves the result to the shared surface.
        id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
        [encoder setComputePipelineState:_opaqueCopy];
        [encoder setTexture:_metalFXOutput atIndex:0];
        [encoder setTexture:target atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(outputWidth, outputHeight, 1)
            threadsPerThreadgroup:MTLSizeMake(_opaqueCopy.threadExecutionWidth, 1, 1)];
        [encoder endEncoding];

        [commands commit];
        [commands waitUntilCompleted];
        if (commands.status != MTLCommandBufferStatusCompleted) {
            failure = [NSString stringWithFormat:@"MetalFX 실행 실패: %@", commands.error.localizedDescription];
        }
    } else {
        failure = @"MetalFX 텍스처를 만들지 못함";
    }
    if (sourceHolder) {
        CFRelease(sourceHolder);
    }
    if (targetHolder) {
        CFRelease(targetHolder);
    }
    return failure;
}

/// First format of a frame processor's attribute dictionary, or the preferred one when it is allowed
static OSType processorFormat(NSDictionary *attributes, OSType preferred)
{
    id value = attributes[(id) kCVPixelBufferPixelFormatTypeKey];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *) value unsignedIntValue];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *formats = value;
        if (preferred && [formats containsObject:@(preferred)]) {
            return preferred;
        }
        if (formats.count > 0) {
            return [(NSNumber *) formats.firstObject unsignedIntValue];
        }
    }
    return preferred ?: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

- (void)startLowLatencySessionWidth:(size_t)width height:(size_t)height
{
    if (!VTLowLatencySuperResolutionScalerConfiguration.isSupported) {
        self.sessionFailure = @"이 기기는 저지연 초해상도를 지원하지 않음";
        self.sessionState = OBSUpscaleSessionFailed;
        return;
    }

    NSArray<NSNumber *> *factors = [VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:width
                                                                                                          frameHeight:height];
    CMVideoDimensions maximum = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions;
    blog(LOG_INFO, "[upscale] low latency SR: factors for %zux%zu: %s, maximum source %dx%d", width, height,
         [factors componentsJoinedByString:@", "].UTF8String, maximum.width, maximum.height);

    const float needed = (float) kOBSAVUpscaleHeight / (float) height;
    float chosen = 0.0f;
    for (NSNumber *factor in factors) {
        if (factor.floatValue >= needed - 0.001f && (chosen == 0.0f || factor.floatValue < chosen)) {
            chosen = factor.floatValue;
        }
    }
    if (chosen == 0.0f) {
        self.sessionFailure = [NSString stringWithFormat:@"%zux%zu에 쓸 배율 없음 (지원: %@, 최대 원본 %dx%d)", width, height,
                                                         [factors componentsJoinedByString:@", "], maximum.width, maximum.height];
        self.sessionState = OBSUpscaleSessionFailed;
        return;
    }

    VTLowLatencySuperResolutionScalerConfiguration *configuration =
        [[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:(NSInteger) width
                                                                       frameHeight:(NSInteger) height
                                                                       scaleFactor:chosen];
    VTFrameProcessor *processor = [[VTFrameProcessor alloc] init];
    NSError *error = nil;
    const uint64_t start = os_gettime_ns();
    if (![processor startSessionWithConfiguration:configuration error:&error]) {
        self.sessionFailure = [NSString stringWithFormat:@"세션 시작 실패: %@", error.localizedDescription];
        self.sessionState = OBSUpscaleSessionFailed;
        return;
    }
    blog(LOG_INFO, "[upscale] low latency SR: session started at %.2fx in %.0f ms", chosen,
         (double) (os_gettime_ns() - start) / 1e6);

    self.sessionFactor = chosen;
    self.sessionConfiguration = configuration;
    self.sessionProcessor = processor;
    self.sessionState = OBSUpscaleSessionReady;
}

- (void)startImageSRSessionWidth:(size_t)width height:(size_t)height
{
    if (!VTSuperResolutionScalerConfiguration.isSupported) {
        self.sessionFailure = @"이 기기는 초해상도를 지원하지 않음";
        self.sessionState = OBSUpscaleSessionFailed;
        return;
    }

    NSArray<NSNumber *> *factors = VTSuperResolutionScalerConfiguration.supportedScaleFactors;
    blog(LOG_INFO, "[upscale] image SR: factors %s", [factors componentsJoinedByString:@", "].UTF8String);

    const float needed = (float) kOBSAVUpscaleHeight / (float) height;
    NSInteger chosen = 0;
    for (NSNumber *factor in factors) {
        if (factor.floatValue >= needed - 0.001f && (chosen == 0 || factor.integerValue < chosen)) {
            chosen = factor.integerValue;
        }
    }
    if (chosen == 0) {
        self.sessionFailure = [NSString stringWithFormat:@"쓸 배율 없음 (지원: %@)", [factors componentsJoinedByString:@", "]];
        self.sessionState = OBSUpscaleSessionFailed;
        return;
    }

    VTSuperResolutionScalerConfiguration *configuration = [[VTSuperResolutionScalerConfiguration alloc]
         initWithFrameWidth:(NSInteger) width
                frameHeight:(NSInteger) height
                scaleFactor:chosen
                  inputType:VTSuperResolutionScalerConfigurationInputTypeImage
         usePrecomputedFlow:NO
      qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal
                   revision:VTSuperResolutionScalerConfiguration.defaultRevision];
    if (!configuration) {
        self.sessionFailure = [NSString stringWithFormat:@"%zux%zu는 범위 밖 (이미지 입력은 iOS에서 1920x1080까지)", width, height];
        self.sessionState = OBSUpscaleSessionFailed;
        return;
    }

    __weak OBSAVUpscaler *weakSelf = self;
    void (^start)(void) = ^{
        OBSAVUpscaler *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        VTFrameProcessor *processor = [[VTFrameProcessor alloc] init];
        NSError *error = nil;
        const uint64_t startTime = os_gettime_ns();
        if (![processor startSessionWithConfiguration:configuration error:&error]) {
            strongSelf.sessionFailure = [NSString stringWithFormat:@"세션 시작 실패: %@", error.localizedDescription];
            strongSelf.sessionState = OBSUpscaleSessionFailed;
            return;
        }
        blog(LOG_INFO, "[upscale] image SR: session started at %ldx in %.0f ms", (long) chosen,
             (double) (os_gettime_ns() - startTime) / 1e6);
        strongSelf.sessionFactor = (float) chosen;
        strongSelf.sessionConfiguration = configuration;
        strongSelf.sessionProcessor = processor;
        strongSelf.sessionState = OBSUpscaleSessionReady;
    };

    if (configuration.configurationModelStatus == VTSuperResolutionScalerConfigurationModelStatusReady) {
        start();
        return;
    }

    blog(LOG_INFO, "[upscale] image SR: downloading the model");
    self.sessionProgress = @"모델 다운로드 중";
    self.sessionConfiguration = configuration;
    dispatch_queue_t setupQueue = _setupQueue;
    [configuration downloadConfigurationModelWithCompletionHandler:^(NSError *error) {
        OBSAVUpscaler *strongSelf = weakSelf;
        if (error) {
            blog(LOG_WARNING, "[upscale] image SR: download failed: %s", error.localizedDescription.UTF8String);
            strongSelf.sessionFailure = [NSString stringWithFormat:@"모델 다운로드 실패: %@", error.localizedDescription];
            strongSelf.sessionState = OBSUpscaleSessionFailed;
            return;
        }
        blog(LOG_INFO, "[upscale] image SR: model downloaded");
        strongSelf.sessionProgress = nil;
        dispatch_async(setupQueue, start);
    }];
}

/// YES when the session of this mode and size is ready. Otherwise it is loading or failed, see sessionFailure.
- (BOOL)prepareSessionForMode:(NSString *)mode width:(size_t)width height:(size_t)height
{
    if (self.sessionState != OBSUpscaleSessionNone && [self.sessionMode isEqualToString:mode] &&
        self.sessionWidth == width && self.sessionHeight == height) {
        return self.sessionState == OBSUpscaleSessionReady;
    }

    [self endSession];
    self.sessionMode = mode;
    self.sessionWidth = width;
    self.sessionHeight = height;
    self.sessionFailure = nil;
    self.sessionProgress = nil;
    self.sessionState = OBSUpscaleSessionLoading;

    // Loading the model takes longer than a frame, the capture queue keeps sending the original until it is ready
    __weak OBSAVUpscaler *weakSelf = self;
    dispatch_async(_setupQueue, ^{
        OBSAVUpscaler *strongSelf = weakSelf;
        // The mode was changed again while this waited for its turn
        if (![strongSelf.sessionMode isEqualToString:mode]) {
            return;
        }
        if ([mode isEqualToString:kModeLowLatencySR]) {
            [strongSelf startLowLatencySessionWidth:width height:height];
        } else {
            [strongSelf startImageSRSessionWidth:width height:height];
        }
    });
    return NO;
}

- (nullable NSString *)runProcessorFrom:(CVPixelBufferRef)source mode:(NSString *)mode to:(CVPixelBufferRef)output
{
    const size_t width = CVPixelBufferGetWidth(source);
    const size_t height = CVPixelBufferGetHeight(source);
    id configuration = self.sessionConfiguration;
    NSDictionary *sourceAttributes = [configuration sourcePixelBufferAttributes];
    NSDictionary *targetAttributes = [configuration destinationPixelBufferAttributes];

    const size_t targetWidth = (size_t) lround((double) width * self.sessionFactor);
    const size_t targetHeight = (size_t) lround((double) height * self.sessionFactor);
    const OSType captureFormat = CVPixelBufferGetPixelFormatType(source);
    const OSType sourceFormat = processorFormat(sourceAttributes, captureFormat);
    const OSType targetFormat = processorFormat(targetAttributes, sourceFormat);

    CVPixelBufferRef input = [self createBufferWidth:width height:height format:sourceFormat attributes:sourceAttributes];
    CVPixelBufferRef result = [self createBufferWidth:targetWidth height:targetHeight format:targetFormat attributes:targetAttributes];
    NSString *failure = nil;

    if (!input || !result) {
        failure = [NSString stringWithFormat:@"처리기 버퍼를 만들지 못함 (%zux%zu)", targetWidth, targetHeight];
    } else if (![self transferFrom:source to:input]) {
        failure = @"처리기 입력 변환 실패";
    } else {
        const CMTime time = CMTimeMake(_frameCounter++, 60);
        VTFrameProcessorFrame *sourceFrame = [[VTFrameProcessorFrame alloc] initWithBuffer:input presentationTimeStamp:time];
        VTFrameProcessorFrame *targetFrame = [[VTFrameProcessorFrame alloc] initWithBuffer:result presentationTimeStamp:time];
        id<VTFrameProcessorParameters> parameters = nil;
        if (sourceFrame && targetFrame) {
            if ([mode isEqualToString:kModeLowLatencySR]) {
                parameters = [[VTLowLatencySuperResolutionScalerParameters alloc] initWithSourceFrame:sourceFrame
                                                                                     destinationFrame:targetFrame];
            } else {
                parameters = [[VTSuperResolutionScalerParameters alloc]
                    initWithSourceFrame:sourceFrame
                          previousFrame:nil
                    previousOutputFrame:nil
                            opticalFlow:nil
                         submissionMode:VTSuperResolutionScalerParametersSubmissionModeRandom
                       destinationFrame:targetFrame];
            }
        }
        NSError *error = nil;
        VTFrameProcessor *processor = self.sessionProcessor;
        if (!parameters) {
            failure = @"처리기 입력을 만들지 못함";
        } else if (![processor processWithParameters:parameters error:&error]) {
            failure = [NSString stringWithFormat:@"처리 실패: %@", error.localizedDescription];
        } else if (![self transferFrom:result to:output]) {
            failure = @"처리 결과 변환 실패";
        }
    }
    CVPixelBufferRelease(input);
    CVPixelBufferRelease(result);
    return failure;
}

#endif  // OBS_UPSCALE_DEVICE_ONLY

- (void)endSession
{
#ifdef OBS_UPSCALE_DEVICE_ONLY
    if (@available(iOS 26.0, *)) {
        VTFrameProcessor *processor = self.sessionProcessor;
        [processor endSession];
    }
#endif
    self.sessionProcessor = nil;
    self.sessionConfiguration = nil;
    self.sessionState = OBSUpscaleSessionNone;
}

/// nil when `output` holds the result. A failure text otherwise; `*loading` says it is only not ready yet.
- (nullable NSString *)runMode:(NSString *)mode from:(CVPixelBufferRef)source to:(CVPixelBufferRef)output loading:(BOOL *)loading
{
    if ([mode isEqualToString:kModeTransfer]) {
        return [self transferFrom:source to:output] ? nil : @"픽셀 전송 실패";
    }

    if ([mode isEqualToString:kModeLowLatencySR] || [mode isEqualToString:kModeImageSR]) {
#ifdef OBS_UPSCALE_DEVICE_ONLY
        if (@available(iOS 26.0, *)) {
            if (![self prepareSessionForMode:mode
                                       width:CVPixelBufferGetWidth(source)
                                      height:CVPixelBufferGetHeight(source)]) {
                if (self.sessionState == OBSUpscaleSessionFailed) {
                    return self.sessionFailure ?: @"세션 실패";
                }
                *loading = YES;
                return self.sessionProgress ?: @"모델 불러오는 중";
            }
            return [self runProcessorFrom:source mode:mode to:output];
        }
        return @"iOS 26 이상 필요";
#else
        return @"시뮬레이터에서는 쓸 수 없음";
#endif
    }

    CVPixelBufferRef bgra = [self createBGRAFrom:source];
    if (!bgra) {
        return @"BGRA 변환 실패";
    }

    NSString *failure = nil;
    if ([mode isEqualToString:kModeMPSBilinear] || [mode isEqualToString:kModeMPSLanczos]) {
        if (!_device || !MPSSupportsMTLDevice(_device)) {
            failure = @"이 GPU는 MPS를 지원하지 않음";
        } else if ([mode isEqualToString:kModeMPSBilinear]) {
            _mpsBilinear = _mpsBilinear ?: [[MPSImageBilinearScale alloc] initWithDevice:_device];
            failure = [self runMPS:_mpsBilinear from:bgra to:output] ? nil : @"MPS 실행 실패";
        } else {
            _mpsLanczos = _mpsLanczos ?: [[MPSImageLanczosScale alloc] initWithDevice:_device];
            failure = [self runMPS:_mpsLanczos from:bgra to:output] ? nil : @"MPS 실행 실패";
        }
    } else if ([mode isEqualToString:kModeCILanczos]) {
        failure = [self runCILanczosFrom:bgra to:output] ? nil : @"Core Image 실패";
    } else if ([mode isEqualToString:kModeMetalFX]) {
#ifdef OBS_UPSCALE_DEVICE_ONLY
        failure = [self runMetalFXFrom:bgra to:output];
#else
        failure = @"시뮬레이터에서는 쓸 수 없음";
#endif
    } else {
        failure = [NSString stringWithFormat:@"모르는 방식 %@", mode];
    }
    CVPixelBufferRelease(bgra);
    return failure;
}

- (void)resetWindow
{
    _windowStart = 0;
    _windowFrames = 0;
    _windowTotalNs = 0;
    _windowMaxNs = 0;
    _windowLogCounter = 0;
}

- (void)noteFrameTime:(uint64_t)elapsed mode:(NSString *)mode
{
    const uint64_t now = os_gettime_ns();
    if (_windowStart == 0) {
        _windowStart = now;
    }
    _windowFrames++;
    _windowTotalNs += elapsed;
    _windowMaxNs = MAX(_windowMaxNs, elapsed);

    const uint64_t window = now - _windowStart;
    if (window >= 1000000000ULL) {
        const double average = (double) _windowTotalNs / _windowFrames / 1e6;
        const double maximum = (double) _windowMaxNs / 1e6;
        const double fps = _windowFrames * 1e9 / (double) window;
        self.status = [NSString stringWithFormat:@"%@ %@ %.1f ms (최대 %.1f), %.0f fps", mode, _sizeText, average, maximum, fps];
        if (_windowLogCounter++ % 5 == 0) {
            blog(LOG_INFO, "[upscale] %s %s: avg %.2f ms, max %.2f ms, %.1f fps", mode.UTF8String, _sizeText.UTF8String,
                 average, maximum, fps);
        }
        _windowStart = now;
        _windowFrames = 0;
        _windowTotalNs = 0;
        _windowMaxNs = 0;
    }
}

- (CVPixelBufferRef)createUpscaledFrom:(CVPixelBufferRef)source mode:(NSString *)mode
{
    if (![mode isEqualToString:_currentMode]) {
        blog(LOG_INFO, "[upscale] mode: %s", mode.UTF8String);
        _currentMode = [mode copy];
        _loggedFailure = nil;
        [self resetWindow];
        self.status = [NSString stringWithFormat:@"%@ 시작", mode];
        // A session of the other mode holds its model and is not needed any more
        if (self.sessionState != OBSUpscaleSessionNone) {
            [self endSession];
        }
    }

    const size_t width = CVPixelBufferGetWidth(source);
    const size_t height = CVPixelBufferGetHeight(source);
    if (height >= kOBSAVUpscaleHeight || height == 0) {
        self.status = [NSString stringWithFormat:@"%@: 입력이 %zux%zu라 그대로 보냄", mode, width, height];
        return NULL;
    }

    const size_t outputWidth = (size_t) lround((double) width * kOBSAVUpscaleHeight / height / 2.0) * 2;
    _sizeText = [NSString stringWithFormat:@"%zux%zu→%zux%zu", width, height, outputWidth, kOBSAVUpscaleHeight];

    CVPixelBufferRef output = [self createBufferWidth:outputWidth
                                               height:kOBSAVUpscaleHeight
                                               format:kCVPixelFormatType_32BGRA
                                           attributes:nil];
    if (!output) {
        self.status = [NSString stringWithFormat:@"%@: 출력 버퍼 없음", mode];
        return NULL;
    }

    const uint64_t start = os_gettime_ns();
    BOOL loading = NO;
    NSString *failure = [self runMode:mode from:source to:output loading:&loading];
    if (failure) {
        CVPixelBufferRelease(output);
        self.status = [NSString stringWithFormat:@"%@: %@", mode, failure];
        if (![failure isEqualToString:_loggedFailure]) {
            blog(loading ? LOG_INFO : LOG_WARNING, "[upscale] %s: %s", mode.UTF8String, failure.UTF8String);
            _loggedFailure = failure;
        }
        return NULL;
    }
    _loggedFailure = nil;

    [self noteFrameTime:os_gettime_ns() - start mode:mode];
    if (_textureCache && _windowFrames == 0) {
        CVMetalTextureCacheFlush(_textureCache, 0);
    }
    return output;
}

#pragma mark - Compare

+ (CVPixelBufferRef)createTestPattern
{
    const size_t width = 1920;
    const size_t height = 1080;
    NSDictionary *attributes = @{(id) kCVPixelBufferIOSurfacePropertiesKey: @{}, (id) kCVPixelBufferMetalCompatibilityKey: @YES};
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (__bridge CFDictionaryRef) attributes, &buffer);
    if (!buffer) {
        return NULL;
    }

    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);

    CVPixelBufferLockBaseAddress(buffer, 0);
    // Luma gradient with fine detail at the edges: 1 px lines to see what each mode does with them
    uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    for (size_t y = 0; y < height; y++) {
        uint8_t *row = luma + y * lumaStride;
        for (size_t x = 0; x < width; x++) {
            const uint8_t gradient = (uint8_t) (16 + 219 * x / (width - 1));
            const bool detail = y < 200 && (x % 8 == 0 || y % 8 == 0);
            row[x] = detail ? 235 : gradient;
        }
    }
    uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    for (size_t y = 0; y < height / 2; y++) {
        memset(chroma + y * chromaStride, 128, chromaStride);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

/// Average of a box in the middle of a BGRA frame
static void centerAverage(CVPixelBufferRef buffer, int average[4])
{
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    uint64_t sum[4] = {0, 0, 0, 0};
    const size_t half = 16;
    for (size_t y = height / 2 - half; y < height / 2 + half; y++) {
        const uint8_t *pixel = base + y * stride + (width / 2 - half) * 4;
        for (size_t x = 0; x < half * 2; x++, pixel += 4) {
            for (int channel = 0; channel < 4; channel++) {
                sum[channel] += pixel[channel];
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    for (int channel = 0; channel < 4; channel++) {
        average[channel] = (int) (sum[channel] / (half * half * 4));
    }
}

static BOOL writePNG(CVPixelBufferRef buffer, NSString *path)
{
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: [NSNull null], kCIContextOutputColorSpace: [NSNull null]}];
    });
    CIImage *image = [CIImage imageWithCVPixelBuffer:buffer options:@{kCIImageColorSpace: [NSNull null]}];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSError *error = nil;
    BOOL ok = [context writePNGRepresentationOfImage:image
                                               toURL:[NSURL fileURLWithPath:path]
                                              format:kCIFormatBGRA8
                                          colorSpace:colorSpace
                                             options:@{}
                                               error:&error];
    CGColorSpaceRelease(colorSpace);
    if (!ok) {
        blog(LOG_WARNING, "[upscale] compare: could not write %s: %s", path.lastPathComponent.UTF8String,
             error.localizedDescription.UTF8String);
    }
    return ok;
}

/// Runs in the compare queue. YES unless a mode that works here gave a wrong picture.
+ (BOOL)runCompareOn:(CVPixelBufferRef)frame directory:(NSString *)directory iterations:(int)iterations
{
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    const size_t width = CVPixelBufferGetWidth(frame);
    const size_t height = CVPixelBufferGetHeight(frame);
    const size_t outputWidth = (size_t) lround((double) width * kOBSAVUpscaleHeight / height / 2.0) * 2;
    const OSType format = CVPixelBufferGetPixelFormatType(frame);

    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"입력 %zux%zu ('%c%c%c%c') → %zux%zu, 방식마다 %d번\n", width, height, (char) (format >> 24), (char) (format >> 16),
                         (char) (format >> 8), (char) format, outputWidth, kOBSAVUpscaleHeight, iterations];
    [report appendString:@"형식: 방식 | 첫 실행 ms | 평균 ms | 최대 ms | 가운데 BGRA 평균\n"];

    BOOL ok = YES;
    int worked = 0;
    int referenceGreen = -1;

    for (NSString *mode in [self modes]) {
        @autoreleasepool {
            OBSAVUpscaler *upscaler = [[OBSAVUpscaler alloc] init];
            CVPixelBufferRef output = [upscaler createBufferWidth:outputWidth
                                                           height:kOBSAVUpscaleHeight
                                                           format:kCVPixelFormatType_32BGRA
                                                       attributes:nil];
            NSString *failure = output ? nil : @"출력 버퍼 없음";
            double first = 0.0;
            double total = 0.0;
            double maximum = 0.0;

            if (!failure) {
                // The first run starts sessions: wait for the model up to 2 minutes
                const uint64_t waitStart = os_gettime_ns();
                while (YES) {
                    const uint64_t start = os_gettime_ns();
                    BOOL loading = NO;
                    failure = [upscaler runMode:mode from:frame to:output loading:&loading];
                    if (!loading) {
                        first = (double) (os_gettime_ns() - (first == 0.0 ? waitStart : start)) / 1e6;
                        break;
                    }
                    if (os_gettime_ns() - waitStart > 120000000000ULL) {
                        failure = [NSString stringWithFormat:@"2분 안에 준비되지 않음 (%@)", failure];
                        break;
                    }
                    [NSThread sleepForTimeInterval:0.05];
                }
            }

            for (int i = 0; i < iterations && !failure; i++) {
                const uint64_t start = os_gettime_ns();
                BOOL loading = NO;
                failure = [upscaler runMode:mode from:frame to:output loading:&loading];
                const double elapsed = (double) (os_gettime_ns() - start) / 1e6;
                total += elapsed;
                maximum = MAX(maximum, elapsed);
            }

            if (failure) {
                blog(LOG_INFO, "upscale compare: %s unavailable: %s", mode.UTF8String, failure.UTF8String);
                [report appendFormat:@"%@ | 안 됨: %@\n", mode, failure];
                // These two do not depend on the GPU's features, so they must work everywhere
                if ([mode isEqualToString:kModeTransfer] || [mode isEqualToString:kModeCILanczos]) {
                    ok = NO;
                }
            } else {
                int center[4];
                centerAverage(output, center);
                const BOOL opaque = center[3] >= 250;
                // Same picture as the first mode, give or take what scaling does to the fine detail
                if (referenceGreen < 0) {
                    referenceGreen = center[1];
                }
                const BOOL sameBrightness = abs(center[1] - referenceGreen) <= 24;
                if (!opaque || !sameBrightness) {
                    ok = NO;
                }
                worked++;
                const double average = total / MAX(iterations, 1);
                blog(LOG_INFO, "upscale compare: %s first %.1f ms, avg %.2f ms, max %.2f ms, center %d,%d,%d,%d%s", mode.UTF8String,
                     first, average, maximum, center[0], center[1], center[2], center[3],
                     (opaque && sameBrightness) ? "" : " WRONG PICTURE");
                [report appendFormat:@"%@ | %.1f | %.2f | %.2f | %d,%d,%d,%d\n", mode, first, average, maximum, center[0], center[1],
                                     center[2], center[3]];
                writePNG(output, [directory stringByAppendingPathComponent:[mode stringByAppendingString:@".png"]]);
            }
            CVPixelBufferRelease(output);
            [upscaler endSession];
        }
    }

    // The source itself, at its own size, to compare with
    OBSAVUpscaler *converter = [[OBSAVUpscaler alloc] init];
    CVPixelBufferRef source = [converter createBGRAFrom:frame];
    if (source) {
        writePNG(source, [directory stringByAppendingPathComponent:@"source.png"]);
        CVPixelBufferRelease(source);
    }

    [report writeToFile:[directory stringByAppendingPathComponent:@"report.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    blog(LOG_INFO, "upscale compare: done, %d modes worked, saved to %s", worked, directory.UTF8String);
    return ok && worked > 0;
}

+ (void)compareFrame:(CVPixelBufferRef)frame name:(NSString *)name iterations:(int)iterations completion:(void (^)(BOOL))completion
{
    OBSAVUpscaler *copier = [[OBSAVUpscaler alloc] init];
    CVPixelBufferRef copy = [copier createBufferWidth:CVPixelBufferGetWidth(frame)
                                               height:CVPixelBufferGetHeight(frame)
                                               format:CVPixelBufferGetPixelFormatType(frame)
                                           attributes:nil];
    if (!copy || ![copier transferFrom:frame to:copy]) {
        blog(LOG_WARNING, "upscale compare: could not copy the frame");
        CVPixelBufferRelease(copy);
        if (completion) {
            completion(NO);
        }
        return;
    }

    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [[documents stringByAppendingPathComponent:@"upscale-compare"] stringByAppendingPathComponent:name];
    blog(LOG_INFO, "upscale compare: started on %zux%zu", CVPixelBufferGetWidth(copy), CVPixelBufferGetHeight(copy));

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const BOOL ok = [OBSAVUpscaler runCompareOn:copy directory:directory iterations:iterations];
        CVPixelBufferRelease(copy);
        if (completion) {
            completion(ok);
        }
    });
}

@end
