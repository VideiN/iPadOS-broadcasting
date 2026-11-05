//
//  OBSAVUpscaler.h
//  mac-avcapture (iOS port)
//
//  Upscales capture frames to 1440p so the options can be compared on a real device.
//  Everything here is an experiment: keep the mode that wins and delete the others.
//

#pragma once

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Output height of every mode. The width follows the source's aspect ratio.
static const size_t kOBSAVUpscaleHeight = 1440;

/// Not thread safe: one upscaler belongs to one capture queue.
@interface OBSAVUpscaler : NSObject

/// Identifiers stored in the source's "upscale" setting, without "off"
+ (NSArray<NSString *> *)modes;
+ (NSString *)labelForMode:(NSString *)mode;

/// Returns a new BGRA buffer of the output size, with opaque alpha. Returns NULL when the frame should go out as it is:
/// the mode is still loading (see `status`), is not supported here, or failed.
- (nullable CVPixelBufferRef)createUpscaledFrom:(CVPixelBufferRef)source mode:(NSString *)mode CF_RETURNS_RETAINED;

/// What the mode is doing, for the diagnostics overlay and the log. Safe to read from any thread.
@property (atomic, readonly, copy) NSString *status;

/// Same frame through every mode, on a queue of its own: PNGs and report.txt in Documents/upscale-compare/<name>.
/// `iterations` is the number of timed runs per mode. The frame is copied, so the capture buffer is not held.
+ (void)compareFrame:(CVPixelBufferRef)frame
                name:(NSString *)name
          iterations:(int)iterations
          completion:(nullable void (^)(BOOL ok))completion;

/// 1080p NV12 test pattern (limited range, Rec.709) for CI, where the simulator has no camera
+ (nullable CVPixelBufferRef)createTestPattern CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
