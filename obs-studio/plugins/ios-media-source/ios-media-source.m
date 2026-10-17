/* iOS port: media (video/audio file) source based on AVFoundation (plan D8: no FFmpeg video/audio decoders).
 *
 * A playback thread decodes the file with AVAssetReader (hardware decoding through VideoToolbox) and hands frames and
 * audio to libobs as an async source, each at its presentation time. Videos with a rotation (portrait phone videos)
 * are read through a video composition so the frames come out upright.
 *
 * Media controls (play/pause, restart, stop, time, duration) work through libobs' media API. */

@import AVFoundation;

#include <obs-module.h>
#include <util/platform.h>
#include <util/threading.h>

#include <math.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("ios-media-source", "en-US")

#define LOG(level, format, ...) blog(level, "[ios-media-source: '%s'] " format, obs_source_get_name(media->source), ##__VA_ARGS__)

/* How far ahead of its time audio is handed to libobs (video goes at its time) */
#define AUDIO_LEAD_NS 100000000ULL

struct ios_media {
    obs_source_t *source;

    pthread_mutex_t mutex; /* settings below */
    char *path;
    bool looping;
    bool restart_on_activate;

    pthread_t thread;
    bool thread_valid;
    volatile bool stop;    /* ends the playback thread */
    volatile bool paused;
    volatile bool restart; /* start again from the beginning */
    volatile long state;   /* enum obs_media_state */

    volatile long duration_ms;
    volatile long time_ms;
};

static const char *ios_media_get_name(void *unused)
{
    UNUSED_PARAMETER(unused);
    return obs_module_text("MediaSource");
}

#pragma mark - Playback

/* Sleeps until "deadline" (os_gettime_ns time); returns early (false) when the thread should stop or restart */
static bool wait_until(struct ios_media *media, uint64_t deadline)
{
    for (;;) {
        if (os_atomic_load_bool(&media->stop) || os_atomic_load_bool(&media->restart)) {
            return false;
        }
        const uint64_t now = os_gettime_ns();
        if (now >= deadline) {
            return true;
        }
        const uint64_t step = deadline - now;
        os_sleepto_ns(now + (step > 10000000ULL ? 10000000ULL : step));
    }
}

static void output_video(struct ios_media *media, CMSampleBufferRef sample, uint64_t timestamp)
{
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (!image || CVPixelBufferGetPlaneCount(image) != 2) {
        return;
    }

    struct obs_source_frame frame = {0};
    frame.format = VIDEO_FORMAT_NV12;
    frame.width = (uint32_t) CVPixelBufferGetWidth(image);
    frame.height = (uint32_t) CVPixelBufferGetHeight(image);
    frame.timestamp = timestamp;

    const bool full_range = CVPixelBufferGetPixelFormatType(image) ==
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    frame.full_range = full_range;

    enum video_colorspace colorspace = VIDEO_CS_709;
    CFTypeRef matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, NULL);
    if (matrix) {
        if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
            colorspace = VIDEO_CS_601;
        }
        CFRelease(matrix);
    }
    video_format_get_parameters_for_format(colorspace, full_range ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL,
                                           frame.format, frame.color_matrix, frame.color_range_min,
                                           frame.color_range_max);

    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    for (size_t plane = 0; plane < 2; plane++) {
        frame.data[plane] = CVPixelBufferGetBaseAddressOfPlane(image, plane);
        frame.linesize[plane] = (uint32_t) CVPixelBufferGetBytesPerRowOfPlane(image, plane);
    }
    obs_source_output_video(media->source, &frame); /* copies the frame */
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
}

static void output_audio(struct ios_media *media, CMSampleBufferRef sample, uint64_t timestamp)
{
    CMBlockBufferRef block = NULL;
    AudioBufferList list;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample, NULL, &list, sizeof(list), kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
    if (status != noErr || list.mNumberBuffers < 1) {
        return;
    }

    struct obs_source_audio audio = {0};
    audio.data[0] = list.mBuffers[0].mData;
    audio.frames = (uint32_t) CMSampleBufferGetNumSamples(sample);
    audio.speakers = SPEAKERS_STEREO;
    audio.format = AUDIO_FORMAT_FLOAT;
    audio.samples_per_sec = 48000;
    audio.timestamp = timestamp;
    obs_source_output_audio(media->source, &audio);

    if (block) {
        CFRelease(block);
    }
}

/* Plays the file once. Returns false if it could not be read. "base" is the os_gettime_ns time of position 0, moved
 * forward while paused. */
static bool play_once(struct ios_media *media, NSURL *url, uint64_t *base, bool *first_frame_logged)
{
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (!reader) {
        LOG(LOG_WARNING, "cannot read '%s': %s", url.path.UTF8String, error.localizedDescription.UTF8String);
        return false;
    }

    os_atomic_set_long(&media->duration_ms,
                       (long) (CMTimeGetSeconds(asset.duration) * 1000.0));

    AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audioTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;

    AVAssetReaderOutput *videoOutput = nil;
    if (videoTrack) {
        NSDictionary *videoSettings = @{
            (__bridge NSString *) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        };

        if (!CGAffineTransformIsIdentity(videoTrack.preferredTransform)) {
            // Rotated video (e.g. portrait from a phone): a video composition applies the rotation
            AVAssetReaderVideoCompositionOutput *composition =
                [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:@[videoTrack]
                                                                                        videoSettings:videoSettings];
            composition.videoComposition = [AVVideoComposition videoCompositionWithPropertiesOfAsset:asset];
            videoOutput = composition;
        } else {
            videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack
                                                                     outputSettings:videoSettings];
        }
        videoOutput.alwaysCopiesSampleData = NO;
        if ([reader canAddOutput:videoOutput]) {
            [reader addOutput:videoOutput];
        } else {
            videoOutput = nil;
        }
    }

    AVAssetReaderTrackOutput *audioOutput = nil;
    if (audioTrack) {
        audioOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:@{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsNonInterleaved: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVSampleRateKey: @48000,
            AVNumberOfChannelsKey: @2,
        }];
        audioOutput.alwaysCopiesSampleData = NO;
        if ([reader canAddOutput:audioOutput]) {
            [reader addOutput:audioOutput];
        } else {
            audioOutput = nil;
        }
    }

    if ((!videoOutput && !audioOutput) || ![reader startReading]) {
        LOG(LOG_WARNING, "cannot play '%s': %s", url.path.UTF8String,
            reader.error.localizedDescription.UTF8String ?: "no audio or video track");
        return false;
    }

    CMSampleBufferRef nextVideo = videoOutput ? [videoOutput copyNextSampleBuffer] : NULL;
    CMSampleBufferRef nextAudio = audioOutput ? [audioOutput copyNextSampleBuffer] : NULL;
    bool keepGoing = true;

    while ((nextVideo || nextAudio) && keepGoing) {
        @autoreleasepool {
            while (os_atomic_load_bool(&media->paused) && !os_atomic_load_bool(&media->stop) &&
                   !os_atomic_load_bool(&media->restart)) {
                os_sleep_ms(10);
                *base += 10000000ULL;
            }

            const CMTime videoTime = nextVideo ? CMSampleBufferGetPresentationTimeStamp(nextVideo) : kCMTimePositiveInfinity;
            const CMTime audioTime = nextAudio ? CMSampleBufferGetPresentationTimeStamp(nextAudio) : kCMTimePositiveInfinity;
            const bool takeVideo = CMTimeCompare(videoTime, audioTime) <= 0;
            const CMTime time = takeVideo ? videoTime : audioTime;
            const uint64_t timestamp = *base + (uint64_t) llround(fmax(CMTimeGetSeconds(time), 0.0) * 1e9);

            if (takeVideo) {
                keepGoing = wait_until(media, timestamp);
                if (keepGoing) {
                    output_video(media, nextVideo, timestamp);
                    os_atomic_set_long(&media->time_ms, (long) (CMTimeGetSeconds(time) * 1000.0));
                    if (!*first_frame_logged) {
                        *first_frame_logged = true;
                        CVImageBufferRef image = CMSampleBufferGetImageBuffer(nextVideo);
                        LOG(LOG_INFO, "first video frame %zux%zu", image ? CVPixelBufferGetWidth(image) : 0,
                            image ? CVPixelBufferGetHeight(image) : 0);
                    }
                }
                CFRelease(nextVideo);
                nextVideo = keepGoing ? [videoOutput copyNextSampleBuffer] : NULL;
            } else {
                keepGoing = wait_until(media, timestamp > AUDIO_LEAD_NS ? timestamp - AUDIO_LEAD_NS : 0);
                if (keepGoing) {
                    output_audio(media, nextAudio, timestamp);
                    if (!videoOutput) {
                        os_atomic_set_long(&media->time_ms,
                                           (long) (CMTimeGetSeconds(time) * 1000.0));
                    }
                }
                CFRelease(nextAudio);
                nextAudio = keepGoing ? [audioOutput copyNextSampleBuffer] : NULL;
            }
        }
    }

    if (nextVideo) {
        CFRelease(nextVideo);
    }
    if (nextAudio) {
        CFRelease(nextAudio);
    }
    [reader cancelReading];

    // Continue the next loop right after the end of this one
    *base += (uint64_t) llround(fmax(CMTimeGetSeconds(asset.duration), 0.0) * 1e9);
    return true;
}

static void *playback_thread(void *data)
{
    struct ios_media *media = data;
    os_set_thread_name("ios-media-source");

    pthread_mutex_lock(&media->mutex);
    NSString *path = media->path ? @(media->path) : nil;
    pthread_mutex_unlock(&media->mutex);
    NSURL *url = path.length ? [NSURL fileURLWithPath:path] : nil;

    bool first_frame_logged = false;

    while (url && !os_atomic_load_bool(&media->stop)) {
        @autoreleasepool {
            os_atomic_set_bool(&media->restart, false);
            os_atomic_set_long(&media->state, OBS_MEDIA_STATE_PLAYING);

            uint64_t base = os_gettime_ns() + 50000000ULL;
            bool loop = true;
            int plays = 0;

            while (loop && !os_atomic_load_bool(&media->stop) && !os_atomic_load_bool(&media->restart)) {
                if (!play_once(media, url, &base, &first_frame_logged)) {
                    os_atomic_set_long(&media->state, OBS_MEDIA_STATE_ERROR);
                    break;
                }
                plays++;

                pthread_mutex_lock(&media->mutex);
                loop = media->looping;
                pthread_mutex_unlock(&media->mutex);

                if (loop && !os_atomic_load_bool(&media->stop) && !os_atomic_load_bool(&media->restart) &&
                    plays <= 2) {
                    LOG(LOG_INFO, "looping (play %d)", plays + 1);
                }
            }
        }

        if (os_atomic_load_bool(&media->restart)) {
            continue;
        }

        if (os_atomic_load_long(&media->state) != OBS_MEDIA_STATE_ERROR) {
            os_atomic_set_long(&media->state, OBS_MEDIA_STATE_ENDED);
            obs_source_media_ended(media->source);
            obs_source_output_video(media->source, NULL);
        }

        // Ended (or failed): wait until restarted or stopped
        while (!os_atomic_load_bool(&media->stop) && !os_atomic_load_bool(&media->restart)) {
            os_sleep_ms(20);
        }
    }

    return NULL;
}

static void stop_thread(struct ios_media *media)
{
    if (media->thread_valid) {
        os_atomic_set_bool(&media->stop, true);
        pthread_join(media->thread, NULL);
        media->thread_valid = false;
    }
    os_atomic_set_bool(&media->stop, false);
    os_atomic_set_bool(&media->paused, false);
    os_atomic_set_long(&media->state, OBS_MEDIA_STATE_STOPPED);
    os_atomic_set_long(&media->time_ms, 0);
}

static void start_thread(struct ios_media *media)
{
    stop_thread(media);

    pthread_mutex_lock(&media->mutex);
    const bool has_file = media->path && *media->path;
    pthread_mutex_unlock(&media->mutex);

    if (!has_file) {
        obs_source_output_video(media->source, NULL);
        return;
    }

    if (pthread_create(&media->thread, NULL, playback_thread, media) == 0) {
        media->thread_valid = true;
    } else {
        LOG(LOG_ERROR, "cannot start the playback thread");
    }
}

#pragma mark - Source

static void ios_media_update(void *data, obs_data_t *settings)
{
    struct ios_media *media = data;
    const char *path = obs_data_get_string(settings, "local_file");

    pthread_mutex_lock(&media->mutex);
    const bool path_changed = !media->path || strcmp(media->path, path) != 0;
    bfree(media->path);
    media->path = bstrdup(path);
    media->looping = obs_data_get_bool(settings, "looping");
    media->restart_on_activate = obs_data_get_bool(settings, "restart_on_activate");
    pthread_mutex_unlock(&media->mutex);

    if (path_changed || !media->thread_valid) {
        LOG(LOG_INFO, "file '%s'%s", path, media->looping ? ", looping" : "");
        start_thread(media);
    }
}

static void *ios_media_create(obs_data_t *settings, obs_source_t *source)
{
    struct ios_media *media = bzalloc(sizeof(struct ios_media));
    media->source = source;
    pthread_mutex_init(&media->mutex, NULL);
    os_atomic_set_long(&media->state, OBS_MEDIA_STATE_NONE);
    ios_media_update(media, settings);
    return media;
}

static void ios_media_destroy(void *data)
{
    struct ios_media *media = data;
    stop_thread(media);
    bfree(media->path);
    pthread_mutex_destroy(&media->mutex);
    bfree(media);
}

static void ios_media_activate(void *data)
{
    struct ios_media *media = data;
    pthread_mutex_lock(&media->mutex);
    const bool restart = media->restart_on_activate;
    pthread_mutex_unlock(&media->mutex);

    if (restart && media->thread_valid) {
        os_atomic_set_bool(&media->paused, false);
        os_atomic_set_bool(&media->restart, true);
    }
}

static void ios_media_play_pause(void *data, bool pause)
{
    struct ios_media *media = data;
    os_atomic_set_bool(&media->paused, pause);
    if (os_atomic_load_long(&media->state) == OBS_MEDIA_STATE_PLAYING ||
        os_atomic_load_long(&media->state) == OBS_MEDIA_STATE_PAUSED) {
        os_atomic_set_long(&media->state, pause ? OBS_MEDIA_STATE_PAUSED : OBS_MEDIA_STATE_PLAYING);
    }
}

static void ios_media_restart(void *data)
{
    struct ios_media *media = data;
    if (!media->thread_valid) {
        start_thread(media);
        return;
    }
    os_atomic_set_bool(&media->paused, false);
    os_atomic_set_bool(&media->restart, true);
}

static void ios_media_stop(void *data)
{
    struct ios_media *media = data;
    stop_thread(media);
    obs_source_output_video(media->source, NULL);
}

static int64_t ios_media_get_duration(void *data)
{
    return os_atomic_load_long(&((struct ios_media *) data)->duration_ms);
}

static int64_t ios_media_get_time(void *data)
{
    return os_atomic_load_long(&((struct ios_media *) data)->time_ms);
}

static enum obs_media_state ios_media_get_state(void *data)
{
    return (enum obs_media_state) os_atomic_load_long(&((struct ios_media *) data)->state);
}

static void ios_media_get_defaults(obs_data_t *settings)
{
    obs_data_set_default_bool(settings, "looping", true);
    obs_data_set_default_bool(settings, "restart_on_activate", true);
}

static obs_properties_t *ios_media_get_properties(void *data)
{
    UNUSED_PARAMETER(data);
    obs_properties_t *props = obs_properties_create();

    obs_properties_add_path(props, "local_file", obs_module_text("LocalFile"), OBS_PATH_FILE,
                            "Media (*.mp4 *.mov *.m4v *.m4a *.mp3 *.wav *.aac);;All files (*.*)", NULL);
    obs_properties_add_bool(props, "looping", obs_module_text("Looping"));
    obs_properties_add_bool(props, "restart_on_activate", obs_module_text("RestartOnActivate"));
    return props;
}

static struct obs_source_info ios_media_info = {
    .id = "ios_media_source",
    .type = OBS_SOURCE_TYPE_INPUT,
    .output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO | OBS_SOURCE_DO_NOT_DUPLICATE |
                    OBS_SOURCE_CONTROLLABLE_MEDIA,
    .icon_type = OBS_ICON_TYPE_MEDIA,
    .get_name = ios_media_get_name,
    .create = ios_media_create,
    .destroy = ios_media_destroy,
    .update = ios_media_update,
    .activate = ios_media_activate,
    .get_defaults = ios_media_get_defaults,
    .get_properties = ios_media_get_properties,
    .media_play_pause = ios_media_play_pause,
    .media_restart = ios_media_restart,
    .media_stop = ios_media_stop,
    .media_get_duration = ios_media_get_duration,
    .media_get_time = ios_media_get_time,
    .media_get_state = ios_media_get_state,
};

bool obs_module_load(void)
{
    obs_register_source(&ios_media_info);
    return true;
}
