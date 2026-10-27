// 녹화(Hybrid MP4)와 RTMP/RTMPS 송출 (P3)
//
// 인코더는 VideoToolbox(H.264/HEVC)와 AudioToolbox AAC만 쓴다 (계획 D6, D7).
// 녹화는 obs-outputs의 mp4_output으로, 녹화 중에는 조각 단위로 써서 앱이 강제 종료돼도 파일을 살릴 수 있고
// 끝나면 일반 MP4로 정리된다 (Hybrid MP4).

#include "obs-core.h"

#include <obs.h>
#include <util/dstr.h>
#include <util/platform.h>
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

static bool is_srt_url(const char *url)
{
	return url && strncasecmp(url, "srt://", 6) == 0;
}

static const char *service_get_protocol(void *data)
{
	struct app_service *service = data;
	if (is_srt_url(service->server))
		return "SRT";
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
		// SRT에서는 같은 값(OBS_SERVICE_CONNECT_INFO_STREAM_ID)이 streamid다 (비어 있으면 URL의 streamid=…).
		// 암호는 URL의 passphrase=…
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
	struct app_service *service = data;
	return is_srt_url(service->server) ? "ffmpeg_mpegts_muxer" : "rtmp_output";
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
	obs_output_t *replay;
	obs_service_t *service;

	// 위의 포인터를 만들고 바꾸고 놓는 일 (P13): 시작·중지·저장이 잡는다. 메인의 상태 조회는 trylock이라
	// 시작이 오래 걸려도 막히지 않고, 그동안은 마지막 결과(last_stats)를 돌려준다
	pthread_mutex_t ops;
	struct core_output_stats last_stats;

	pthread_mutex_t mutex; // 아래 마지막 결과
	int record_stop_code;
	int stream_stop_code;
	char record_error[512];
	char stream_error[512];
	int replay_saved_count;
	char replay_last_path[1024];
	int record_stop_count;
	int stream_stop_count;
	int stream_start_count;
	uint64_t reconnect_since; // 재연결을 시작한 시각 (os_gettime_ns, 0이면 아님)
} out = {.ops = PTHREAD_MUTEX_INITIALIZER, .mutex = PTHREAD_MUTEX_INITIALIZER};

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
		out.reconnect_since = 0;
		out.stream_stop_count++;
		out.stream_stop_code = code;
		snprintf(out.stream_error, sizeof(out.stream_error), "%s", text);
	} else {
		out.record_stop_count++;
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

static void stream_started(void *param, calldata_t *cd)
{
	output_signal_log(param, cd);
	pthread_mutex_lock(&out.mutex);
	out.stream_start_count++;
	pthread_mutex_unlock(&out.mutex);
}

// 재연결 중인 시간을 상태 줄에 보이려고 시작 시각을 둔다
static void stream_reconnecting(void *param, calldata_t *cd)
{
	output_signal_log(param, cd);
	pthread_mutex_lock(&out.mutex);
	if (!out.reconnect_since)
		out.reconnect_since = os_gettime_ns();
	pthread_mutex_unlock(&out.mutex);
}

static void stream_reconnected(void *param, calldata_t *cd)
{
	output_signal_log(param, cd);
	pthread_mutex_lock(&out.mutex);
	out.reconnect_since = 0;
	pthread_mutex_unlock(&out.mutex);
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
	if (is_stream)
		signal_handler_connect(handler, "start", stream_started, (void *)"streaming started");
	else
		signal_handler_connect(handler, "start", output_signal_log, (void *)"recording started");
	if (is_stream) {
		signal_handler_connect(handler, "reconnect", stream_reconnecting, (void *)"streaming reconnecting");
		signal_handler_connect(handler, "reconnect_success", stream_reconnected,
				       (void *)"streaming reconnected");
	}
	return output;
}

#pragma mark - 인코더

static const char *codec_name(int codec)
{
	return codec == CORE_CODEC_HEVC ? "hevc" : "h264";
}

static const char *rate_control_name(int rate_control)
{
	switch (rate_control) {
	case CORE_RC_ABR:
		return "ABR";
	case CORE_RC_CRF:
		return "CRF";
	default:
		return "CBR";
	}
}

// mac-videotoolbox의 profile 값. HEVC는 main만 쓴다 (8비트 캔버스)
static const char *profile_name(const struct core_video_encoding *video)
{
	if (video->codec == CORE_CODEC_HEVC)
		return "main";
	switch (video->profile) {
	case CORE_PROFILE_BASELINE:
		return "baseline";
	case CORE_PROFILE_MAIN:
		return "main";
	default:
		return "high";
	}
}

// 앱이 넘긴 값을 인코더가 받을 수 있는 범위로 맞춘다
static struct core_video_encoding checked_video(const struct core_video_encoding *video)
{
	struct core_video_encoding checked = *video;
	if (checked.bitrate_kbps < 50)
		checked.bitrate_kbps = 6000;
	if (checked.quality < 0 || checked.quality > 100)
		checked.quality = 60;
	if (checked.max_bitrate_kbps < 50)
		checked.max_bitrate_kbps = checked.bitrate_kbps;
	if (!(checked.max_bitrate_window > 0.0))
		checked.max_bitrate_window = 1.5;
	if (checked.keyint_sec < 1)
		checked.keyint_sec = 2;
	if (checked.keyint_sec > 20)
		checked.keyint_sec = 20;
	if (!checked.width || !checked.height)
		checked.width = checked.height = 0;
	if (checked.scale_type <= OBS_SCALE_DISABLE || checked.scale_type > OBS_SCALE_AREA)
		checked.scale_type = OBS_SCALE_BICUBIC;
	return checked;
}

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

static obs_encoder_t *create_video_encoder(const struct core_video_encoding *video, const char *name)
{
	const char *codec = codec_name(video->codec);
	const char *id = find_video_encoder(codec);
	if (!id) {
		blog(LOG_WARNING, "[app] no %s video encoder", codec);
		return NULL;
	}

	obs_data_t *settings = obs_data_create();
	obs_data_set_string(settings, "rate_control", rate_control_name(video->rate_control));
	obs_data_set_int(settings, "bitrate", video->bitrate_kbps);
	obs_data_set_int(settings, "quality", video->quality);
	obs_data_set_bool(settings, "limit_bitrate", video->limit_bitrate);
	obs_data_set_int(settings, "max_bitrate", video->max_bitrate_kbps);
	obs_data_set_double(settings, "max_bitrate_window", video->max_bitrate_window);
	obs_data_set_int(settings, "keyint_sec", video->keyint_sec);
	obs_data_set_string(settings, "profile", profile_name(video));
	obs_data_set_bool(settings, "bframes", video->bframes);
	obs_encoder_t *encoder = obs_video_encoder_create(id, name, settings, NULL);
	obs_data_release(settings);
	if (!encoder)
		return NULL;

	obs_encoder_set_video(encoder, obs_get_video());
	// 캔버스와 다른 출력 크기는 GPU에서 줄인다 (인코더만 쓰는 비디오 믹스가 생긴다)
	if (video->width && video->height) {
		obs_encoder_set_scaled_size(encoder, video->width, video->height);
		obs_encoder_set_gpu_scale_type(encoder, (enum obs_scale_type)video->scale_type);
	}

	char rate[64];
	if (video->rate_control == CORE_RC_CRF)
		snprintf(rate, sizeof(rate), "CRF quality %d", video->quality);
	else
		snprintf(rate, sizeof(rate), "%s %d kbps", rate_control_name(video->rate_control), video->bitrate_kbps);
	char limit[64] = "";
	if (video->limit_bitrate && video->rate_control != CORE_RC_CBR)
		snprintf(limit, sizeof(limit), " (max %d kbps over %.2f s)", video->max_bitrate_kbps,
			 video->max_bitrate_window);
	blog(LOG_INFO, "[app] %s: %s, %s%s, keyframe %d s, %s, profile %s, output %ux%u", name, id, rate, limit,
	     video->keyint_sec, video->bframes ? "B-frames" : "no B-frames", profile_name(video),
	     obs_encoder_get_width(encoder), obs_encoder_get_height(encoder));
	return encoder;
}

static obs_encoder_t *create_audio_encoder(const struct core_audio_encoding *audio, const char *name)
{
	obs_data_t *settings = obs_data_create();
	obs_data_set_int(settings, "bitrate", audio->bitrate_kbps);
	obs_data_set_bool(settings, "allow he-aac", audio->he_aac);
	obs_encoder_t *encoder = obs_audio_encoder_create("CoreAudio_AAC", name, settings, 0, NULL);
	obs_data_release(settings);

	if (encoder)
		obs_encoder_set_audio(encoder, obs_get_audio());
	else
		blog(LOG_WARNING, "[app] no AAC encoder");
	return encoder;
}

// 쓰는 중인 인코더는 그대로 둔다 (녹화와 리플레이가 같이 쓴다). 쉬고 있으면 새로 만든다:
// 코덱·출력 크기·스케일은 만든 인코더에서 바꿀 수 없고, 캔버스를 바꿨을 수도 있다.
static obs_encoder_t *prepare_video_encoder(obs_encoder_t *encoder, const struct core_video_encoding *video,
					    const char *name)
{
	if (encoder && obs_encoder_active(encoder))
		return encoder;
	obs_encoder_release(encoder);
	return create_video_encoder(video, name);
}

static obs_encoder_t *prepare_audio_encoder(obs_encoder_t *encoder, const struct core_audio_encoding *audio,
					    const char *name)
{
	if (encoder && obs_encoder_active(encoder))
		return encoder;
	obs_encoder_release(encoder);
	return create_audio_encoder(audio, name);
}

static struct core_audio_encoding checked_audio(const struct core_audio_encoding *audio)
{
	struct core_audio_encoding checked = *audio;
	if (checked.bitrate_kbps < 32)
		checked.bitrate_kbps = 160;
	return checked;
}

bool core_outputs_active(void)
{
	if (pthread_mutex_trylock(&out.ops) != 0) {
		// 시작·중지 중이면 켜진 것으로 본다 (캔버스 바꾸기 등을 막는 쪽이 안전하다)
		return true;
	}
	const bool active = (out.recording && obs_output_active(out.recording)) ||
			    (out.streaming && obs_output_active(out.streaming)) ||
			    (out.replay && obs_output_active(out.replay));
	pthread_mutex_unlock(&out.ops);
	return active;
}

#pragma mark - 녹화

static bool start_recording_with(const char *path, const struct core_video_encoding *video,
				 const struct core_audio_encoding *audio)
{
	out.record_video = prepare_video_encoder(out.record_video, video, "Record Video");
	out.record_audio = prepare_audio_encoder(out.record_audio, audio, "Record Audio");
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

	const char *codec = obs_encoder_get_codec(out.record_video);
	if (obs_output_start(out.recording)) {
		blog(LOG_INFO, "[app] recording to %s (%s %d kbps, AAC %d kbps)", path, codec, video->bitrate_kbps,
		     audio->bitrate_kbps);
		return true;
	}

	const char *error = obs_output_get_last_error(out.recording);
	blog(LOG_WARNING, "[app] recording failed to start with %s: %s", codec, error ? error : "unknown error");
	return false;
}

static bool recording_start(const char *path, const struct core_video_encoding *video_in,
			    const struct core_audio_encoding *audio_in)
{
	if (out.recording && obs_output_active(out.recording))
		return true;

	pthread_mutex_lock(&out.mutex);
	out.record_error[0] = 0;
	pthread_mutex_unlock(&out.mutex);

	struct core_video_encoding video = checked_video(video_in);
	struct core_audio_encoding audio = checked_audio(audio_in);
	if (start_recording_with(path, &video, &audio))
		return true;

	// 그 코덱의 인코더를 만들 수 없는 환경(예: 시뮬레이터)에서는 H.264로 다시 시도한다
	if (video.codec != CORE_CODEC_H264) {
		video.codec = CORE_CODEC_H264;
		return start_recording_with(path, &video, &audio);
	}
	return false;
}

// 보통 멈춤은 인코더가 멈춘 시점까지의 패킷을 다 받은 뒤 끝난다. 인코더가 밀려 끝나지 않으면 강제로 멈춘다.
static void recording_stop(bool force)
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

bool core_recording_start(const char *path, const struct core_video_encoding *video,
			  const struct core_audio_encoding *audio)
{
	pthread_mutex_lock(&out.ops);
	const bool ok = recording_start(path, video, audio);
	pthread_mutex_unlock(&out.ops);
	return ok;
}

void core_recording_stop(bool force)
{
	pthread_mutex_lock(&out.ops);
	recording_stop(force);
	pthread_mutex_unlock(&out.ops);
}

#pragma mark - 송출

// HEVC는 Enhanced RTMP로 보낸다 (받는 쪽이 지원해야 한다, O4)
static bool streaming_start(const char *server, const char *key, const struct core_video_encoding *video_in,
			    const struct core_audio_encoding *audio_in, const struct core_stream_options *options)
{
	if (out.streaming && obs_output_active(out.streaming))
		return true;

	pthread_mutex_lock(&out.mutex);
	out.stream_error[0] = 0;
	pthread_mutex_unlock(&out.mutex);

	const struct core_video_encoding video = checked_video(video_in);
	const struct core_audio_encoding audio = checked_audio(audio_in);

	obs_data_t *settings = obs_data_create();
	obs_data_set_string(settings, "server", server);
	obs_data_set_string(settings, "key", key);
	if (!out.service)
		out.service = obs_service_create("app_rtmp_service", "Stream Target", settings, NULL);
	else
		obs_service_update(out.service, settings);
	obs_data_release(settings);

	out.stream_video = prepare_video_encoder(out.stream_video, &video, "Stream Video");
	out.stream_audio = prepare_audio_encoder(out.stream_audio, &audio, "Stream Audio");

	// RTMP/RTMPS는 rtmp_output, SRT는 obs-ffmpeg의 mpegts 출력 (P5). 프로토콜이 바뀌면 출력을 다시 만든다
	const bool srt = is_srt_url(server);
	const char *output_id = srt ? "ffmpeg_mpegts_muxer" : "rtmp_output";
	if (out.streaming && strcmp(obs_output_get_id(out.streaming), output_id) != 0) {
		obs_output_release(out.streaming);
		out.streaming = NULL;
	}
	if (!out.streaming)
		out.streaming = create_output(output_id, "Streaming", true);
	if (!out.service || !out.stream_video || !out.stream_audio || !out.streaming)
		return false;

	// 연결 옵션 (P11): 재연결, 송출 지연, 네트워크가 막힐 때 비트레이트 조절(rtmp_output만)
	const int retries = options->reconnect ? (options->retries > 0 ? options->retries : 20) : 0;
	const int retry_sec = options->retry_sec > 0 ? options->retry_sec : 5;
	const int delay_sec = options->delay_sec > 0 ? options->delay_sec : 0;
	obs_output_set_reconnect_settings(out.streaming, retries, retry_sec);
	obs_output_set_delay(out.streaming, (uint32_t)delay_sec, OBS_OUTPUT_DELAY_PRESERVE);
	if (!srt) {
		obs_data_t *output_settings = obs_data_create();
		obs_data_set_bool(output_settings, "dyn_bitrate", options->dyn_bitrate);
		obs_output_update(out.streaming, output_settings);
		obs_data_release(output_settings);
	}

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

	// 서버 주소는 남기되 스트림 키와 URL의 옵션(SRT passphrase 등)은 로그에 남기지 않는다
	video_t *video_out = obs_encoder_video(out.stream_video);
	const char *query = strchr(server, '?');
	blog(LOG_INFO, "[app] streaming to %.*s%s (%s %s %d kbps at %.2f fps %ux%u, keyframe %d s, %s, AAC %d kbps)",
	     query ? (int)(query - server) : (int)strlen(server), server, query ? "?…" : "",
	     obs_encoder_get_codec(out.stream_video), rate_control_name(video.rate_control), video.bitrate_kbps,
	     video_out ? video_output_get_frame_rate(video_out) : 0.0, obs_encoder_get_width(out.stream_video),
	     obs_encoder_get_height(out.stream_video), video.keyint_sec, video.bframes ? "B-frames" : "no B-frames",
	     audio.bitrate_kbps);
	blog(LOG_INFO, "[app] streaming options: reconnect %s (%d x %d s), delay %d s, dynamic bitrate %s",
	     retries ? "on" : "off", retries, retry_sec, delay_sec,
	     srt ? "n/a (SRT)" : (options->dyn_bitrate ? (delay_sec ? "off (delay)" : "on") : "off"));
	return true;
}

static void streaming_stop(bool force)
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

bool core_streaming_start(const char *server, const char *key, const struct core_video_encoding *video,
			  const struct core_audio_encoding *audio, const struct core_stream_options *options)
{
	pthread_mutex_lock(&out.ops);
	const bool ok = streaming_start(server, key, video, audio, options);
	pthread_mutex_unlock(&out.ops);
	return ok;
}

void core_streaming_stop(bool force)
{
	pthread_mutex_lock(&out.ops);
	streaming_stop(force);
	pthread_mutex_unlock(&out.ops);
}

#pragma mark - 리플레이 버퍼

// obs-outputs의 ios_replay_buffer: 마지막 몇 초의 인코딩된 패킷을 메모리에 두었다가 저장하면 MP4로 쓴다.
// 녹화 인코더를 같이 쓴다 (녹화와 리플레이를 함께 켜도 하드웨어 인코더 세션이 늘지 않는다).

static void replay_saved(void *param, calldata_t *cd)
{
	UNUSED_PARAMETER(param);
	const char *path = calldata_string(cd, "path");
	blog(LOG_INFO, "[app] replay saved: %s", path ? path : "");

	pthread_mutex_lock(&out.mutex);
	out.replay_saved_count++;
	snprintf(out.replay_last_path, sizeof(out.replay_last_path), "%s", path ? path : "");
	pthread_mutex_unlock(&out.mutex);
}

static void replay_stopped(void *param, calldata_t *cd)
{
	UNUSED_PARAMETER(param);
	const int code = (int)calldata_int(cd, "code");
	blog(code == OBS_OUTPUT_SUCCESS ? LOG_INFO : LOG_WARNING, "[app] replay buffer stopped: %s (%d)",
	     stop_code_text(code), code);
}

static bool start_replay_with(const char *directory, int seconds, int max_mb, const struct core_video_encoding *video,
			      const struct core_audio_encoding *audio)
{
	out.record_video = prepare_video_encoder(out.record_video, video, "Record Video");
	out.record_audio = prepare_audio_encoder(out.record_audio, audio, "Record Audio");
	if (!out.replay) {
		out.replay = obs_output_create("ios_replay_buffer", "Replay Buffer", NULL, NULL);
		if (out.replay) {
			signal_handler_t *handler = obs_output_get_signal_handler(out.replay);
			signal_handler_connect(handler, "saved", replay_saved, NULL);
			signal_handler_connect(handler, "stop", replay_stopped, NULL);
		}
	}
	if (!out.replay || !out.record_video || !out.record_audio)
		return false;

	obs_data_t *settings = obs_data_create();
	obs_data_set_string(settings, "directory", directory);
	obs_data_set_int(settings, "max_time_sec", seconds);
	obs_data_set_int(settings, "max_size_mb", max_mb);
	obs_output_update(out.replay, settings);
	obs_data_release(settings);

	obs_output_set_video_encoder(out.replay, out.record_video);
	obs_output_set_audio_encoder(out.replay, out.record_audio, 0);

	if (obs_output_start(out.replay)) {
		blog(LOG_INFO, "[app] replay buffer: last %d s (up to %d MB) to %s (%s)", seconds, max_mb, directory,
		     obs_encoder_get_codec(out.record_video));
		return true;
	}

	const char *error = obs_output_get_last_error(out.replay);
	blog(LOG_WARNING, "[app] replay buffer failed to start with %s: %s", codec_name(video->codec),
	     error ? error : "unknown error");
	return false;
}

static bool replay_start(const char *directory, int seconds, int max_mb, const struct core_video_encoding *video_in,
			 const struct core_audio_encoding *audio_in)
{
	if (out.replay && obs_output_active(out.replay))
		return true;
	if (seconds < 1)
		seconds = 30;
	if (max_mb < 64)
		max_mb = 2048;

	struct core_video_encoding video = checked_video(video_in);
	const struct core_audio_encoding audio = checked_audio(audio_in);
	if (start_replay_with(directory, seconds, max_mb, &video, &audio))
		return true;
	// 녹화와 같이 그 코덱을 쓸 수 없으면 H.264로
	if (video.codec != CORE_CODEC_H264) {
		video.codec = CORE_CODEC_H264;
		return start_replay_with(directory, seconds, max_mb, &video, &audio);
	}
	return false;
}

bool core_replay_start(const char *directory, int seconds, int max_mb, const struct core_video_encoding *video,
		       const struct core_audio_encoding *audio)
{
	pthread_mutex_lock(&out.ops);
	const bool ok = replay_start(directory, seconds, max_mb, video, audio);
	pthread_mutex_unlock(&out.ops);
	return ok;
}

void core_replay_stop(void)
{
	pthread_mutex_lock(&out.ops);
	if (out.replay)
		obs_output_stop(out.replay);
	pthread_mutex_unlock(&out.ops);
}

void core_replay_save(void)
{
	pthread_mutex_lock(&out.ops);
	if (out.replay && obs_output_active(out.replay)) {
		calldata_t cd = {0};
		proc_handler_call(obs_output_get_proc_handler(out.replay), "save", &cd);
		calldata_free(&cd);
	}
	pthread_mutex_unlock(&out.ops);
}

char *core_replay_last_path(void)
{
	pthread_mutex_lock(&out.mutex);
	char *path = bstrdup(out.replay_last_path);
	pthread_mutex_unlock(&out.mutex);
	return path;
}

#pragma mark - 상태 조회

void core_get_output_stats(struct core_output_stats *stats)
{
	// 시작·중지가 출력을 바꾸는 중이면 기다리지 않고 지난 결과를 준다 (메인 스레드가 부른다)
	if (pthread_mutex_trylock(&out.ops) != 0) {
		pthread_mutex_lock(&out.mutex);
		*stats = out.last_stats;
		pthread_mutex_unlock(&out.mutex);
		return;
	}

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

	if (out.replay) {
		stats->replay_active = obs_output_active(out.replay);
		stats->replay_bytes = obs_output_get_total_bytes(out.replay);
	}

	video_t *video = obs_get_video();
	stats->encoder_skipped_frames = video ? video_output_get_skipped_frames(video) : 0;
	stats->video_total_frames = video ? video_output_get_total_frames(video) : 0;

	pthread_mutex_lock(&out.mutex);
	stats->record_stop_code = out.record_stop_code;
	stats->stream_stop_code = out.stream_stop_code;
	stats->replay_saved_count = out.replay_saved_count;
	stats->record_stop_count = out.record_stop_count;
	stats->stream_stop_count = out.stream_stop_count;
	stats->stream_start_count = out.stream_start_count;
	if (out.reconnect_since && stats->stream_reconnecting)
		stats->stream_reconnect_seconds = (double)(os_gettime_ns() - out.reconnect_since) / 1e9;
	out.last_stats = *stats;
	pthread_mutex_unlock(&out.mutex);
	pthread_mutex_unlock(&out.ops);
}

char *core_output_last_error(bool stream)
{
	pthread_mutex_lock(&out.mutex);
	char *error = bstrdup(stream ? out.stream_error : out.record_error);
	pthread_mutex_unlock(&out.mutex);
	return error;
}
