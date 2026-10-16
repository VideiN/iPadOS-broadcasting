// 녹화(Hybrid MP4)와 RTMP/RTMPS 송출 (P3)
//
// 인코더는 VideoToolbox(H.264/HEVC)와 AudioToolbox AAC만 쓴다 (계획 D6, D7).
// 녹화는 obs-outputs의 mp4_output으로, 녹화 중에는 조각 단위로 써서 앱이 강제 종료돼도 파일을 살릴 수 있고
// 끝나면 일반 MP4로 정리된다 (Hybrid MP4).

#include "obs-core.h"

#include <obs.h>
#include <util/dstr.h>
#include <util/threading.h>

#include <pthread.h>
#include <string.h>
#include <strings.h>

#pragma mark - 송출 대상 서비스

// 서버 URL과 스트림 키만 담는 서비스. rtmp-services 플러그인(서비스 목록을 curl로 갱신)은 쓰지 않는다.
struct app_service {
	char *server;
	char *key;
};

static const char *service_get_name(void *type_data)
{
	UNUSED_PARAMETER(type_data);
	return "App RTMP";
}

static void service_update(void *data, obs_data_t *settings)
{
	struct app_service *service = data;
	bfree(service->server);
	bfree(service->key);
	service->server = bstrdup(obs_data_get_string(settings, "server"));
	service->key = bstrdup(obs_data_get_string(settings, "key"));
}

static void *service_create(obs_data_t *settings, obs_service_t *service)
{
	UNUSED_PARAMETER(service);
	struct app_service *data = bzalloc(sizeof(*data));
	service_update(data, settings);
	return data;
}

static void service_destroy(void *data)
{
	struct app_service *service = data;
	bfree(service->server);
	bfree(service->key);
	bfree(service);
}

static const char *service_get_protocol(void *data)
{
	struct app_service *service = data;
	return service->server && strncasecmp(service->server, "rtmps://", 8) == 0 ? "RTMPS" : "RTMP";
}

static const char *service_get_url(void *data)
{
	return ((struct app_service *)data)->server;
}

static const char *service_get_key(void *data)
{
	return ((struct app_service *)data)->key;
}

static const char *service_get_connect_info(void *data, uint32_t type)
{
	switch (type) {
	case OBS_SERVICE_CONNECT_INFO_SERVER_URL:
		return service_get_url(data);
	case OBS_SERVICE_CONNECT_INFO_STREAM_KEY:
		return service_get_key(data);
	default:
		return NULL;
	}
}

static bool service_can_try_to_connect(void *data)
{
	struct app_service *service = data;
	return service->server && *service->server;
}

static const char *service_get_output_type(void *data)
{
	UNUSED_PARAMETER(data);
	return "rtmp_output";
}

static struct obs_service_info app_service_info = {
	.id = "app_rtmp_service",
	.get_name = service_get_name,
	.create = service_create,
	.destroy = service_destroy,
	.update = service_update,
	.get_url = service_get_url,
	.get_key = service_get_key,
	.get_protocol = service_get_protocol,
	.get_connect_info = service_get_connect_info,
	.can_try_to_connect = service_can_try_to_connect,
	.get_output_type = service_get_output_type,
};

#pragma mark - 상태

static struct {
	obs_encoder_t *record_video;
	obs_encoder_t *record_audio;
	obs_encoder_t *stream_video;
	obs_encoder_t *stream_audio;
	obs_output_t *recording;
	obs_output_t *streaming;
	obs_service_t *service;

	pthread_mutex_t mutex; // 아래 마지막 결과
	int record_stop_code;
	int stream_stop_code;
	char record_error[512];
	char stream_error[512];
} out = {.mutex = PTHREAD_MUTEX_INITIALIZER};

void core_outputs_register(void)
{
	obs_register_service(&app_service_info);
}

static const char *stop_code_text(int code)
{
	switch (code) {
	case OBS_OUTPUT_SUCCESS:
		return "success";
	case OBS_OUTPUT_BAD_PATH:
		return "bad path";
	case OBS_OUTPUT_CONNECT_FAILED:
		return "connect failed";
	case OBS_OUTPUT_INVALID_STREAM:
		return "invalid stream";
	case OBS_OUTPUT_ERROR:
		return "error";
	case OBS_OUTPUT_DISCONNECTED:
		return "disconnected";
	case OBS_OUTPUT_UNSUPPORTED:
		return "unsupported";
	case OBS_OUTPUT_NO_SPACE:
		return "no space";
	case OBS_OUTPUT_ENCODE_ERROR:
		return "encode error";
	default:
		return "unknown";
	}
}

static void output_stopped(void *param, calldata_t *cd)
{
	const bool is_stream = param != NULL;
	obs_output_t *output = calldata_ptr(cd, "output");
	const int code = (int)calldata_int(cd, "code");
	const char *error = obs_output_get_last_error(output);

	blog(code == OBS_OUTPUT_SUCCESS ? LOG_INFO : LOG_WARNING, "[app] %s stopped: %s (%d)%s%s",
	     is_stream ? "streaming" : "recording", stop_code_text(code), code, error ? ": " : "", error ? error : "");

	// 정상 종료면 오류 문장을 비운다
	const char *text = code == OBS_OUTPUT_SUCCESS ? "" : (error ? error : stop_code_text(code));

	pthread_mutex_lock(&out.mutex);
	if (is_stream) {
		out.stream_stop_code = code;
		snprintf(out.stream_error, sizeof(out.stream_error), "%s", text);
	} else {
		out.record_stop_code = code;
		snprintf(out.record_error, sizeof(out.record_error), "%s", text);
	}
	pthread_mutex_unlock(&out.mutex);
}

static void output_signal_log(void *param, calldata_t *cd)
{
	UNUSED_PARAMETER(cd);
	blog(LOG_INFO, "[app] %s", (const char *)param);
}

static obs_output_t *create_output(const char *id, const char *name, bool is_stream)
{
	obs_output_t *output = obs_output_create(id, name, NULL, NULL);
	if (!output) {
		blog(LOG_ERROR, "[app] failed to create output %s", id);
		return NULL;
	}

	signal_handler_t *handler = obs_output_get_signal_handler(output);
	signal_handler_connect(handler, "stop", output_stopped, is_stream ? (void *)1 : NULL);
	signal_handler_connect(handler, "start", output_signal_log,
			       (void *)(is_stream ? "streaming started" : "recording started"));
	if (is_stream) {
		signal_handler_connect(handler, "reconnect", output_signal_log, (void *)"streaming reconnecting");
		signal_handler_connect(handler, "reconnect_success", output_signal_log,
				       (void *)"streaming reconnected");
	}
	return output;
}

#pragma mark - 인코더

// codec("h264"/"hevc")을 내는 첫 비디오 인코더. iPad에서는 VideoToolbox 하드웨어 인코더뿐이다.
static const char *find_video_encoder(const char *codec)
{
	const char *id;
	for (size_t i = 0; obs_enum_encoder_types(i, &id); i++) {
		if (obs_get_encoder_type(id) == OBS_ENCODER_VIDEO && strcmp(obs_get_encoder_codec(id), codec) == 0)
			return id;
	}
	return NULL;
}

static obs_encoder_t *create_video_encoder(const char *codec, const char *name, const char *rate_control,
					   int bitrate_kbps)
{
	const char *id = find_video_encoder(codec);
	if (!id) {
		blog(LOG_WARNING, "[app] no %s video encoder", codec);
		return NULL;
	}

	obs_data_t *settings = obs_data_create();
	obs_data_set_string(settings, "rate_control", rate_control);
	obs_data_set_int(settings, "bitrate", bitrate_kbps);
	obs_data_set_int(settings, "keyint_sec", 2);
	obs_encoder_t *encoder = obs_video_encoder_create(id, name, settings, NULL);
	obs_data_release(settings);

	if (encoder) {
		obs_encoder_set_video(encoder, obs_get_video());
		blog(LOG_INFO, "[app] %s: %s, %s %d kbps", name, id, rate_control, bitrate_kbps);
	}
	return encoder;
}

static obs_encoder_t *create_audio_encoder(const char *name, int bitrate_kbps)
{
	obs_data_t *settings = obs_data_create();
	obs_data_set_int(settings, "bitrate", bitrate_kbps);
	obs_encoder_t *encoder = obs_audio_encoder_create("CoreAudio_AAC", name, settings, 0, NULL);
	obs_data_release(settings);

	if (encoder)
		obs_encoder_set_audio(encoder, obs_get_audio());
	else
		blog(LOG_WARNING, "[app] no AAC encoder");
	return encoder;
}

// 인코더를 원하는 코덱·설정으로 맞춘다. 쓰는 중이면 그대로 둔다.
// 캔버스를 바꿨을 수 있으므로 지금 비디오 출력에 다시 붙인다.
static obs_encoder_t *prepare_video_encoder(obs_encoder_t *encoder, const char *codec, const char *name,
					    const char *rate_control, int bitrate_kbps)
{
	if (encoder && obs_encoder_active(encoder))
		return encoder;

	if (encoder && strcmp(obs_encoder_get_codec(encoder), codec) != 0) {
		obs_encoder_release(encoder);
		encoder = NULL;
	}
	if (!encoder)
		return create_video_encoder(codec, name, rate_control, bitrate_kbps);

	obs_data_t *settings = obs_encoder_get_settings(encoder);
	obs_data_set_string(settings, "rate_control", rate_control);
	obs_data_set_int(settings, "bitrate", bitrate_kbps);
	obs_encoder_update(encoder, settings);
	obs_data_release(settings);

	obs_encoder_set_video(encoder, obs_get_video());
	return encoder;
}

static obs_encoder_t *prepare_audio_encoder(obs_encoder_t *encoder, const char *name, int bitrate_kbps)
{
	if (encoder && obs_encoder_active(encoder))
		return encoder;
	if (!encoder)
		return create_audio_encoder(name, bitrate_kbps);

	obs_data_t *settings = obs_encoder_get_settings(encoder);
	obs_data_set_int(settings, "bitrate", bitrate_kbps);
	obs_encoder_update(encoder, settings);
	obs_data_release(settings);
	return encoder;
}

bool core_outputs_active(void)
{
	return (out.recording && obs_output_active(out.recording)) ||
	       (out.streaming && obs_output_active(out.streaming));
}

#pragma mark - 녹화

static bool start_recording_with(const char *codec, const char *path, int video_kbps, int audio_kbps)
{
	out.record_video = prepare_video_encoder(out.record_video, codec, "Record Video", "ABR", video_kbps);
	out.record_audio = prepare_audio_encoder(out.record_audio, "Record Audio", audio_kbps);
	if (!out.recording)
		out.recording = create_output("mp4_output", "Recording", false);
	if (!out.recording || !out.record_video || !out.record_audio)
		return false;

	obs_data_t *settings = obs_data_create();
	obs_data_set_string(settings, "path", path);
	obs_output_update(out.recording, settings);
	obs_data_release(settings);

	obs_output_set_video_encoder(out.recording, out.record_video);
	obs_output_set_audio_encoder(out.recording, out.record_audio, 0);

	if (obs_output_start(out.recording)) {
		blog(LOG_INFO, "[app] recording to %s (%s %d kbps, AAC %d kbps)", path, codec, video_kbps, audio_kbps);
		return true;
	}

	const char *error = obs_output_get_last_error(out.recording);
	blog(LOG_WARNING, "[app] recording failed to start with %s: %s", codec, error ? error : "unknown error");
	return false;
}

bool core_recording_start(const char *path, const char *codec, int video_kbps, int audio_kbps)
{
	if (out.recording && obs_output_active(out.recording))
		return true;

	pthread_mutex_lock(&out.mutex);
	out.record_error[0] = 0;
	pthread_mutex_unlock(&out.mutex);

	if (start_recording_with(codec, path, video_kbps, audio_kbps))
		return true;

	// 그 코덱의 인코더를 만들 수 없는 환경(예: 시뮬레이터)에서는 H.264로 다시 시도한다
	if (strcmp(codec, "h264") != 0)
		return start_recording_with("h264", path, video_kbps, audio_kbps);
	return false;
}

// 보통 멈춤은 인코더가 멈춘 시점까지의 패킷을 다 받은 뒤 끝난다. 인코더가 밀려 끝나지 않으면 강제로 멈춘다.
void core_recording_stop(bool force)
{
	if (!out.recording)
		return;

	if (force) {
		blog(LOG_WARNING, "[app] recording: force stop");
		obs_output_force_stop(out.recording);
	} else {
		obs_output_stop(out.recording);
	}
}

#pragma mark - 송출

// codec이 "hevc"면 Enhanced RTMP로 HEVC를 보낸다 (받는 쪽이 지원해야 한다, O4)
bool core_streaming_start(const char *server, const char *key, const char *codec, int video_kbps, int audio_kbps)
{
	if (out.streaming && obs_output_active(out.streaming))
		return true;

	pthread_mutex_lock(&out.mutex);
	out.stream_error[0] = 0;
	pthread_mutex_unlock(&out.mutex);

	obs_data_t *settings = obs_data_create();
	obs_data_set_string(settings, "server", server);
	obs_data_set_string(settings, "key", key);
	if (!out.service)
		out.service = obs_service_create("app_rtmp_service", "Stream Target", settings, NULL);
	else
		obs_service_update(out.service, settings);
	obs_data_release(settings);

	out.stream_video = prepare_video_encoder(out.stream_video, codec, "Stream Video", "CBR", video_kbps);
	out.stream_audio = prepare_audio_encoder(out.stream_audio, "Stream Audio", audio_kbps);
	if (!out.streaming) {
		out.streaming = create_output("rtmp_output", "Streaming", true);
		if (out.streaming)
			obs_output_set_reconnect_settings(out.streaming, 20, 5);
	}
	if (!out.service || !out.stream_video || !out.stream_audio || !out.streaming)
		return false;

	obs_output_set_service(out.streaming, out.service);
	obs_output_set_video_encoder(out.streaming, out.stream_video);
	obs_output_set_audio_encoder(out.streaming, out.stream_audio, 0);

	if (!obs_output_start(out.streaming)) {
		const char *error = obs_output_get_last_error(out.streaming);
		blog(LOG_WARNING, "[app] streaming failed to start: %s", error ? error : "unknown error");
		pthread_mutex_lock(&out.mutex);
		snprintf(out.stream_error, sizeof(out.stream_error), "%s", error ? error : "failed to start");
		pthread_mutex_unlock(&out.mutex);
		return false;
	}

	// 서버 주소는 남기되 스트림 키는 로그에 남기지 않는다
	video_t *video = obs_encoder_video(out.stream_video);
	blog(LOG_INFO, "[app] streaming to %s (%s %d kbps at %.2f fps %ux%u, AAC %d kbps)", server, codec, video_kbps,
	     video ? video_output_get_frame_rate(video) : 0.0, obs_encoder_get_width(out.stream_video),
	     obs_encoder_get_height(out.stream_video), audio_kbps);
	return true;
}

void core_streaming_stop(bool force)
{
	if (!out.streaming)
		return;

	if (force) {
		blog(LOG_WARNING, "[app] streaming: force stop");
		obs_output_force_stop(out.streaming);
	} else {
		obs_output_stop(out.streaming);
	}
}

#pragma mark - 상태 조회

void core_get_output_stats(struct core_output_stats *stats)
{
	memset(stats, 0, sizeof(*stats));

	struct obs_video_info ovi;
	const double fps = obs_get_video_info(&ovi) && ovi.fps_den ? (double)ovi.fps_num / ovi.fps_den : 60.0;

	if (out.recording) {
		stats->recording = obs_output_active(out.recording);
		stats->recording_seconds = obs_output_get_total_frames(out.recording) / fps;
		stats->recording_bytes = obs_output_get_total_bytes(out.recording);
		stats->record_total_frames = obs_output_get_total_frames(out.recording);
	}

	if (out.streaming) {
		stats->streaming = obs_output_active(out.streaming);
		stats->stream_reconnecting = obs_output_reconnecting(out.streaming);
		stats->streaming_seconds = obs_output_get_total_frames(out.streaming) / fps;
		stats->stream_bytes = obs_output_get_total_bytes(out.streaming);
		stats->stream_dropped_frames = obs_output_get_frames_dropped(out.streaming);
		stats->stream_total_frames = obs_output_get_total_frames(out.streaming);
		stats->stream_congestion = obs_output_get_congestion(out.streaming);
	}

	video_t *video = obs_get_video();
	stats->encoder_skipped_frames = video ? video_output_get_skipped_frames(video) : 0;
	stats->video_total_frames = video ? video_output_get_total_frames(video) : 0;

	pthread_mutex_lock(&out.mutex);
	stats->record_stop_code = out.record_stop_code;
	stats->stream_stop_code = out.stream_stop_code;
	pthread_mutex_unlock(&out.mutex);
}

char *core_output_last_error(bool stream)
{
	pthread_mutex_lock(&out.mutex);
	char *error = bstrdup(stream ? out.stream_error : out.record_error);
	pthread_mutex_unlock(&out.mutex);
	return error;
}
