/* iOS port: audio input source for iPadOS.
 *
 * mac-capture reads devices through the CoreAudio HAL, which iOS does not have. On iOS an app records from the one
 * active input route of its AVAudioSession, so this source picks the preferred input port (built-in microphone, USB
 * audio interface, ...) and forwards one or two channels of AVAudioEngine's input node to libobs.
 *
 * Engine (re)configuration runs on a private serial queue. The tap block runs on AVAudioEngine's own thread. */

@import AVFoundation;

#include <obs-module.h>
#include <util/platform.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("ios-audio-input", "en-US")

#define LOG(level, format, ...) blog(level, "[ios-audio-input] " format, ##__VA_ARGS__)

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
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = engine.inputNode;
    AVAudioFormat *format = [inputNode outputFormatForBus:0];

    if (format.channelCount == 0 || format.sampleRate <= 0) {
        LOG(LOG_WARNING, "no audio input available");
        return;
    }

    if (format.commonFormat != AVAudioPCMFormatFloat32 || format.interleaved) {
        LOG(LOG_WARNING, "unexpected input format (common format %ld, interleaved %d)", (long) format.commonFormat,
            format.interleaved);
        return;
    }

    NSInteger first = _firstChannel - 1;
    NSInteger count = _channelCount;

    if (first >= (NSInteger) format.channelCount) {
        first = 0;
    }

    if (first + count > (NSInteger) format.channelCount) {
        count = format.channelCount - first;
    }

    obs_source_t *source = _source;
    const uint32_t firstChannel = (uint32_t) first;
    const uint32_t channels = (uint32_t) count;

    @try {
        [inputNode installTapOnBus:0 bufferSize:(AVAudioFrameCount) (format.sampleRate / 100) format:format
                             block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                                 float *const *data = buffer.floatChannelData;

                                 if (!data || buffer.frameLength == 0) {
                                     return;
                                 }

                                 /* AVAudioTime host time and os_gettime_ns() both count mach absolute time */
                                 uint64_t timestamp =
                                     when.hostTimeValid
                                         ? (uint64_t) ([AVAudioTime secondsForHostTime:when.hostTime] * 1000000000.0)
                                         : os_gettime_ns();

                                 struct obs_source_audio audio = {
                                     .frames = buffer.frameLength,
                                     .speakers = channels == 1 ? SPEAKERS_MONO : SPEAKERS_STEREO,
                                     .format = AUDIO_FORMAT_FLOAT_PLANAR,
                                     .samples_per_sec = (uint32_t) buffer.format.sampleRate,
                                     .timestamp = timestamp,
                                 };

                                 for (uint32_t i = 0; i < channels; i++) {
                                     audio.data[i] = (const uint8_t *) data[firstChannel + i];
                                 }

                                 obs_source_output_audio(source, &audio);
                             }];
    } @catch (NSException *exception) {
        LOG(LOG_ERROR, "installTap failed: %s", exception.reason.UTF8String);
        return;
    }

    [engine prepare];

    NSError *error = nil;

    if (![engine startAndReturnError:&error]) {
        LOG(LOG_ERROR, "engine start failed: %s", error.localizedDescription.UTF8String);
        [inputNode removeTapOnBus:0];
        return;
    }

    _engine = engine;

    LOG(LOG_INFO, "capturing input channel %u%s of %u at %.0f Hz", firstChannel + 1,
        channels == 2 ? [NSString stringWithFormat:@"-%u", firstChannel + 2].UTF8String : "",
        (unsigned) format.channelCount, format.sampleRate);
}

- (void)stopEngine
{
    if (!_engine) {
        return;
    }

    [_engine.inputNode removeTapOnBus:0];
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
