/* iOS port: audio input source for iPadOS.
 *
 * mac-capture reads devices through the CoreAudio HAL, which iOS does not have. On iOS an app records from the one
 * active input route of its AVAudioSession, so this source picks the preferred input port (built-in microphone, USB
 * audio interface, ...) and forwards one or two channels of AVAudioEngine's input node to libobs.
 *
 * Audio is received through an AVAudioSinkNode, which is called on the realtime IO thread once per IO buffer (a few
 * milliseconds), like the AUHAL callback of mac-capture. An input node tap is the fallback: it only delivers about
 * 100 ms per buffer on iOS, which libobs has to absorb with extra audio buffering.
 *
 * Engine (re)configuration runs on a private serial queue. */

@import AVFoundation;

#import <objc/runtime.h>

#include <obs-module.h>
#include <util/platform.h>

#include <math.h>
#include <stdatomic.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("ios-audio-input", "en-US")

#define LOG(level, format, ...) blog(level, "[ios-audio-input] " format, ##__VA_ARGS__)

/* State shared with the audio callbacks of one engine. The callback blocks keep it alive for as long as they can run. */
@interface IOSAudioInputState : NSObject {
@public
    obs_source_t *source;
    uint32_t firstChannel;
    uint32_t channels;
    atomic_bool received;

    /* Delivery statistics, logged every 10 seconds so problems can be told apart on the device (no buffers, silent
     * buffers, late buffers). Only touched by the callback, which runs serially. */
    uint64_t statsStart;
    uint64_t statsBuffers;
    uint64_t statsFrames;
    uint64_t statsMaxDelay;
    float statsPeak;
}
@end

@implementation IOSAudioInputState
@end

/* planes holds every channel of the input; the selected one or two go to libobs */
static void output_audio(__unsafe_unretained IOSAudioInputState *state, float *const *planes, uint32_t planeCount,
                         uint32_t frames, uint32_t sampleRate, uint64_t timestamp)
{
    if (frames == 0 || state->firstChannel + state->channels > planeCount) {
        return;
    }

    uint64_t now = os_gettime_ns();

    struct obs_source_audio audio = {
        .frames = frames,
        .speakers = state->channels == 1 ? SPEAKERS_MONO : SPEAKERS_STEREO,
        .format = AUDIO_FORMAT_FLOAT_PLANAR,
        .samples_per_sec = sampleRate,
        .timestamp = timestamp,
    };

    for (uint32_t i = 0; i < state->channels; i++) {
        const float *samples = planes[state->firstChannel + i];
        audio.data[i] = (const uint8_t *) samples;

        for (uint32_t j = 0; j < frames; j++) {
            state->statsPeak = fmaxf(state->statsPeak, fabsf(samples[j]));
        }
    }

    obs_source_output_audio(state->source, &audio);
    atomic_store(&state->received, true);

    uint64_t delay = now > timestamp ? now - timestamp : 0;
    state->statsBuffers++;
    state->statsFrames += frames;
    state->statsMaxDelay = MAX(state->statsMaxDelay, delay);

    if (state->statsStart == 0) {
        state->statsStart = now;
        LOG(LOG_INFO, "first buffer: %u frames, %.1f ms after capture", frames, delay / 1000000.0);
    } else if (now - state->statsStart >= 10000000000ULL) {
        LOG(LOG_INFO, "%llu buffers (%llu frames each on average), peak %.1f dBFS, max delay %.1f ms",
            state->statsBuffers, state->statsFrames / state->statsBuffers,
            state->statsPeak > 0.0f ? 20.0f * log10f(state->statsPeak) : -INFINITY, state->statsMaxDelay / 1000000.0);
        state->statsStart = now;
        state->statsBuffers = 0;
        state->statsFrames = 0;
        state->statsMaxDelay = 0;
        state->statsPeak = 0.0f;
    }
}

/* AVAudioTime host time and os_gettime_ns() both count mach absolute time */
static uint64_t host_time_to_ns(uint64_t hostTime)
{
    return (uint64_t) ([AVAudioTime secondsForHostTime:hostTime] * 1000000000.0);
}

@interface IOSAudioInput : NSObject
- (instancetype)initWithSource:(obs_source_t *)source;
- (void)updateWithSettings:(obs_data_t *)settings;
- (void)shutdown;
@end

@implementation IOSAudioInput {
    obs_source_t *_source;
    dispatch_queue_t _queue;

    /* Everything below is only touched on _queue */
    NSString *_deviceUID;
    NSInteger _channelCount;
    NSInteger _firstChannel;
    BOOL _measurementMode;

    AVAudioEngine *_engine;
    BOOL _engineUsesTap;
    BOOL _preferTap; /* set when the sink node delivered nothing */
    uint64_t _restartGeneration;
    BOOL _shutDown;
}

- (instancetype)initWithSource:(obs_source_t *)source
{
    self = [super init];

    if (self) {
        _source = source;
        _queue = dispatch_queue_create("ios-audio-input", DISPATCH_QUEUE_SERIAL);
        _deviceUID = @"";
        _channelCount = 2;
        _firstChannel = 1;

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        AVAudioSession *session = [AVAudioSession sharedInstance];

        [center addObserver:self selector:@selector(sessionInterrupted:)
                       name:AVAudioSessionInterruptionNotification
                     object:session];
        [center addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification
                     object:session];
        [center addObserver:self selector:@selector(mediaServicesWereReset:)
                       name:AVAudioSessionMediaServicesWereResetNotification
                     object:session];
        [center addObserver:self selector:@selector(engineConfigurationChanged:)
                       name:AVAudioEngineConfigurationChangeNotification
                     object:nil];
    }

    return self;
}

- (void)updateWithSettings:(obs_data_t *)settings
{
    NSString *deviceUID = @(obs_data_get_string(settings, "device"));
    NSInteger channelCount = obs_data_get_int(settings, "channels") == 1 ? 1 : 2;
    NSInteger firstChannel = MAX(1, (NSInteger) obs_data_get_int(settings, "first_channel"));
    BOOL measurementMode = obs_data_get_bool(settings, "measurement_mode");

    dispatch_async(_queue, ^{
        self->_deviceUID = deviceUID;
        self->_channelCount = channelCount;
        self->_firstChannel = firstChannel;
        self->_measurementMode = measurementMode;
        [self restart];
    });
}

- (void)shutdown
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    dispatch_sync(_queue, ^{
        self->_shutDown = YES;
        self->_restartGeneration++;
        [self stopEngine];
    });
}

#pragma mark - Engine

- (void)restart
{
    [self stopEngine];

    if (_shutDown) {
        return;
    }

    if ([self configureSession]) {
        [self startEngine];
    }
}

- (BOOL)configureSession
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    AVAudioSessionMode mode = _measurementMode ? AVAudioSessionModeMeasurement : AVAudioSessionModeDefault;
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionMixWithOthers |
                                            AVAudioSessionCategoryOptionAllowBluetoothA2DP;

    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:mode options:options error:&error]) {
        LOG(LOG_WARNING, "setCategory failed: %s", error.localizedDescription.UTF8String);
        return NO;
    }

    /* Match the libobs audio settings (48 kHz) so no resampling is needed for most devices */
    [session setPreferredSampleRate:48000 error:nil];
    [session setPreferredIOBufferDuration:0.01 error:nil];

    if (![session setActive:YES error:&error]) {
        LOG(LOG_WARNING, "setActive failed: %s", error.localizedDescription.UTF8String);
        return NO;
    }

    AVAudioSessionPortDescription *preferred = nil;

    if (_deviceUID.length > 0) {
        for (AVAudioSessionPortDescription *port in session.availableInputs) {
            if ([port.UID isEqualToString:_deviceUID]) {
                preferred = port;
                break;
            }
        }

        if (!preferred) {
            LOG(LOG_WARNING, "input '%s' is not available, using the system route", _deviceUID.UTF8String);
        }
    }

    if (![session setPreferredInput:preferred error:&error]) {
        LOG(LOG_WARNING, "setPreferredInput failed: %s", error.localizedDescription.UTF8String);
    }

    /* Multichannel interfaces: only open the channels that are needed */
    NSInteger wanted = _firstChannel - 1 + _channelCount;
    NSInteger maximum = session.maximumInputNumberOfChannels;

    if (maximum > 0) {
        [session setPreferredInputNumberOfChannels:MIN(wanted, maximum) error:nil];
    }

    AVAudioSessionPortDescription *input = session.currentRoute.inputs.firstObject;
    LOG(LOG_INFO, "route: '%s' (%s), %ld of %ld channels, %.0f Hz, IO buffer %.1f ms",
        input ? input.portName.UTF8String : "none", input ? input.portType.UTF8String : "-",
        (long) session.inputNumberOfChannels, (long) maximum, session.sampleRate, session.IOBufferDuration * 1000.0);

    return YES;
}

- (void)startEngine
{
    BOOL useTap = _preferTap;
    AVAudioEngine *engine = useTap ? nil : [self createEngineUsingTap:NO];

    if (!engine) {
        useTap = YES;
        engine = [self createEngineUsingTap:YES];
    }

    if (!engine) {
        return;
    }

    _engine = engine;
    _engineUsesTap = useTap;

    /* The sink node can start without ever being called; fall back to the tap if nothing arrives */
    if (!useTap) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), _queue, ^{
            IOSAudioInputState *state = objc_getAssociatedObject(engine, @selector(startEngine));

            if (self->_engine == engine && state && !atomic_load(&state->received)) {
                LOG(LOG_WARNING, "no audio from the sink node, falling back to an input tap");
                self->_preferTap = YES;
                [self restart];
            }
        });
    }
}

/* Returns a running engine, or nil */
- (AVAudioEngine *)createEngineUsingTap:(BOOL)useTap
{
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = engine.inputNode;
    AVAudioFormat *format = [inputNode outputFormatForBus:0];

    if (format.channelCount == 0 || format.sampleRate <= 0) {
        LOG(LOG_WARNING, "no audio input available");
        return nil;
    }

    if (format.commonFormat != AVAudioPCMFormatFloat32 || format.interleaved) {
        LOG(LOG_WARNING, "unexpected input format (common format %ld, interleaved %d)", (long) format.commonFormat,
            format.interleaved);
        return nil;
    }

    NSInteger first = _firstChannel - 1;
    NSInteger count = _channelCount;

    if (first >= (NSInteger) format.channelCount) {
        first = 0;
    }

    if (first + count > (NSInteger) format.channelCount) {
        count = format.channelCount - first;
    }

    IOSAudioInputState *state = [[IOSAudioInputState alloc] init];
    state->source = _source;
    state->firstChannel = (uint32_t) first;
    state->channels = (uint32_t) count;
    atomic_init(&state->received, false);

    const uint32_t sampleRate = (uint32_t) format.sampleRate;

    @try {
        if (useTap) {
            [inputNode installTapOnBus:0 bufferSize:(AVAudioFrameCount) (format.sampleRate / 100) format:format
                                 block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                                     float *const *planes = buffer.floatChannelData;

                                     if (planes) {
                                         uint64_t timestamp = when.hostTimeValid ? host_time_to_ns(when.hostTime)
                                                                                 : os_gettime_ns();
                                         output_audio(state, planes, buffer.format.channelCount,
                                                      buffer.frameLength, sampleRate, timestamp);
                                     }
                                 }];
        } else {
            AVAudioSinkNode *sink = [[AVAudioSinkNode alloc]
                initWithReceiverBlock:^OSStatus(const AudioTimeStamp *time, AVAudioFrameCount frameCount,
                                                const AudioBufferList *bufferList) {
                    float *planes[64];
                    uint32_t planeCount = MIN(bufferList->mNumberBuffers, 64);

                    for (uint32_t i = 0; i < planeCount; i++) {
                        planes[i] = bufferList->mBuffers[i].mData;
                    }

                    uint64_t timestamp = (time->mFlags & kAudioTimeStampHostTimeValid)
                                             ? host_time_to_ns(time->mHostTime)
                                             : os_gettime_ns();
                    output_audio(state, planes, planeCount, frameCount, sampleRate, timestamp);
                    return noErr;
                }];

            [engine attachNode:sink];
            [engine connect:inputNode to:sink format:format];
        }
    } @catch (NSException *exception) {
        LOG(LOG_ERROR, "%s setup failed: %s", useTap ? "tap" : "sink node", exception.reason.UTF8String);
        return nil;
    }

    [engine prepare];

    NSError *error = nil;

    if (![engine startAndReturnError:&error]) {
        LOG(LOG_ERROR, "engine start failed (%s): %s", useTap ? "tap" : "sink node",
            error.localizedDescription.UTF8String);
        if (useTap) {
            [inputNode removeTapOnBus:0];
        }
        return nil;
    }

    /* Kept with the engine for the sink node watchdog */
    objc_setAssociatedObject(engine, @selector(startEngine), state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LOG(LOG_INFO, "capturing input channel %u%s of %u at %u Hz (%s)", state->firstChannel + 1,
        state->channels == 2 ? [NSString stringWithFormat:@"-%u", state->firstChannel + 2].UTF8String : "",
        (unsigned) format.channelCount, sampleRate, useTap ? "input tap" : "sink node");

    return engine;
}

- (void)stopEngine
{
    if (!_engine) {
        return;
    }

    if (_engineUsesTap) {
        [_engine.inputNode removeTapOnBus:0];
    }

    [_engine stop];
    _engine = nil;
}

#pragma mark - Notifications

/* Route and configuration changes often arrive in bursts, so restarts are coalesced */
- (void)scheduleRestart:(const char *)reason
{
    dispatch_async(_queue, ^{
        if (self->_shutDown) {
            return;
        }

        uint64_t generation = ++self->_restartGeneration;
        LOG(LOG_INFO, "restarting (%s)", reason);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), self->_queue, ^{
            if (generation == self->_restartGeneration) {
                [self restart];
            }
        });
    });
}

- (void)sessionInterrupted:(NSNotification *)notification
{
    NSUInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];

    if (type == AVAudioSessionInterruptionTypeBegan) {
        LOG(LOG_INFO, "audio session interrupted");
    } else {
        [self scheduleRestart:"interruption ended"];
    }
}

- (void)routeChanged:(NSNotification *)notification
{
    NSUInteger reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];

    if (reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable ||
        reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        [self scheduleRestart:"input device added or removed"];
    }
}

- (void)mediaServicesWereReset:(NSNotification *)notification
{
    [self scheduleRestart:"media services were reset"];
}

- (void)engineConfigurationChanged:(NSNotification *)notification
{
    id engine = notification.object;

    dispatch_async(_queue, ^{
        if (engine == self->_engine) {
            [self scheduleRestart:"engine configuration changed"];
        }
    });
}

@end

#pragma mark - obs_source_info

static const char *audio_input_get_name(void *unused)
{
    UNUSED_PARAMETER(unused);
    return obs_module_text("AudioInput");
}

static void *audio_input_create(obs_data_t *settings, obs_source_t *source)
{
    IOSAudioInput *input = [[IOSAudioInput alloc] initWithSource:source];
    [input updateWithSettings:settings];

    return (__bridge_retained void *) input;
}

static void audio_input_destroy(void *data)
{
    IOSAudioInput *input = (__bridge_transfer IOSAudioInput *) data;
    [input shutdown];
}

static void audio_input_update(void *data, obs_data_t *settings)
{
    IOSAudioInput *input = (__bridge IOSAudioInput *) data;
    [input updateWithSettings:settings];
}

static void audio_input_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, "device", "");
    obs_data_set_default_int(settings, "channels", 2);
    obs_data_set_default_int(settings, "first_channel", 1);
    obs_data_set_default_bool(settings, "measurement_mode", false);
}

static obs_properties_t *audio_input_properties(void *data)
{
    UNUSED_PARAMETER(data);

    obs_properties_t *props = obs_properties_create();

    obs_property_t *devices = obs_properties_add_list(props, "device", obs_module_text("Device"), OBS_COMBO_TYPE_LIST,
                                                      OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(devices, obs_module_text("Device.Default"), "");

    for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].availableInputs) {
        obs_property_list_add_string(devices, port.portName.UTF8String, port.UID.UTF8String);
    }

    obs_property_t *channels = obs_properties_add_list(props, "channels", obs_module_text("Channels"),
                                                       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(channels, obs_module_text("Channels.Mono"), 1);
    obs_property_list_add_int(channels, obs_module_text("Channels.Stereo"), 2);

    obs_properties_add_int(props, "first_channel", obs_module_text("FirstChannel"), 1, 64, 1);
    obs_properties_add_bool(props, "measurement_mode", obs_module_text("MeasurementMode"));

    return props;
}

bool obs_module_load(void)
{
    struct obs_source_info info = {
        .id = "ios_audio_input",
        .type = OBS_SOURCE_TYPE_INPUT,
        .output_flags = OBS_SOURCE_AUDIO | OBS_SOURCE_DO_NOT_DUPLICATE,
        .get_name = audio_input_get_name,
        .create = audio_input_create,
        .destroy = audio_input_destroy,
        .update = audio_input_update,
        .get_defaults = audio_input_defaults,
        .get_properties = audio_input_properties,
        .icon_type = OBS_ICON_TYPE_AUDIO_INPUT,
    };

    obs_register_source(&info);
    return true;
}

MODULE_EXPORT const char *obs_module_description(void)
{
    return "iPadOS audio input (AVAudioEngine)";
}
