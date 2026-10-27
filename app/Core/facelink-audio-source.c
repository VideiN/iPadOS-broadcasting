#include "obs-core.h"

#include <obs.h>
#include <util/bmem.h>
#include <util/platform.h>
#include <util/threading.h>

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// 아이폰 마이크 (FaceLink) 소스 (P13): FaceLink.swift가 받은 소리 패킷(docs/face-link.md 3.8, PCM)을 넘기면
// 소스마다 지터 버퍼에 쌓았다가 자기 스레드가 10ms마다 꺼내 libobs에 낸다. 네트워크로 온 소리라 아이패드의
// 입력 경로(하나뿐)와 상관없이 기존 마이크와 같이 섞인다.
//
// - 목표 지연 60ms만큼 차면 내기 시작한다. 빈 순번(잃은 패킷)은 무음으로 채우고, 늦게 온 것은 버린다
// - 아이폰과 아이패드의 오디오 시계는 조금씩 다르다: 버퍼가 목표보다 40ms 넘게 차면 10ms마다 한 표본씩 버리고,
//   20ms 넘게 모자라면 한 표본씩 늘린다 (오래 켜 두어도 지연이 쌓이지 않는다)
// - 0.5초 넘게 안 오면 무음, 다시 오면 버퍼부터 채운다

#define FACELINK_AUDIO_SOURCE_ID "ios_facelink_audio"
#define TARGET_MS 60
#define HIGH_MS (TARGET_MS + 40)
#define LOW_MS (TARGET_MS - 20)
#define CAPACITY_MS 1000
#define MAX_CHANNELS 2

struct facelink_audio {
	obs_source_t *source;
	pthread_mutex_t mutex;
	float *ring; // 섞인(interleaved) 표본
	size_t capacity; // 프레임 수
	size_t head; // 다음에 읽을 프레임
	size_t count; // 쌓인 프레임
	uint32_t rate;
	int channels;
	bool started; // 목표만큼 찬 뒤 내는 중
	uint32_t next_sequence;
	bool have_sequence;
	uint64_t last_packet; // os_gettime_ns

	pthread_t thread;
	bool thread_running;
	atomic_bool stopping;
	float *chunk;
	struct facelink_audio *next; // 소스 목록
};

// 모든 아이폰 마이크 소스 (보통 하나). 받은 패킷은 각 소스에 복사한다
static pthread_mutex_t list_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct facelink_audio *sources;

// 화면에 보일 받기 상태 (전체)
static pthread_mutex_t stats_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct core_facelink_audio_stats stats;

static size_t frames_for_ms(uint32_t rate, int ms)
{
	return (size_t)rate * (size_t)ms / 1000;
}

static void ring_reset(struct facelink_audio *fa, uint32_t rate, int channels)
{
	if (fa->rate != rate || fa->channels != channels || !fa->ring) {
		bfree(fa->ring);
		bfree(fa->chunk);
		fa->rate = rate;
		fa->channels = channels;
		fa->capacity = frames_for_ms(rate, CAPACITY_MS);
		fa->ring = bzalloc(fa->capacity * channels * sizeof(float));
		fa->chunk = bzalloc((frames_for_ms(rate, 10) + 2) * channels * sizeof(float));
	}
	fa->head = 0;
	fa->count = 0;
	fa->started = false;
	fa->have_sequence = false;
}

// 끝에 덧붙인다 (꽉 차면 가장 오래된 것을 버린다)
static void ring_write(struct facelink_audio *fa, const int16_t *pcm, size_t frames)
{
	const int channels = fa->channels;
	for (size_t i = 0; i < frames; i++) {
		if (fa->count == fa->capacity) {
			fa->head = (fa->head + 1) % fa->capacity;
			fa->count--;
		}
		const size_t at = (fa->head + fa->count) % fa->capacity;
		for (int c = 0; c < channels; c++)
			fa->ring[at * channels + c] = pcm ? (float)pcm[i * channels + c] / 32768.0f : 0.0f;
		fa->count++;
	}
}

static void ring_read(struct facelink_audio *fa, float *out, size_t frames)
{
	const int channels = fa->channels;
	for (size_t i = 0; i < frames; i++) {
		const size_t at = (fa->head + i) % fa->capacity;
		memcpy(out + i * channels, fa->ring + at * channels, channels * sizeof(float));
	}
	fa->head = (fa->head + frames) % fa->capacity;
	fa->count -= frames;
}

void core_facelink_audio_push(uint32_t sequence, uint32_t rate, int channels, const int16_t *pcm, int frames)
{
	if (rate < 8000 || rate > 96000 || channels < 1 || channels > MAX_CHANNELS || frames <= 0 || frames > 4096)
		return;
	const uint64_t now = os_gettime_ns();
	int lost = 0, late = 0;

	pthread_mutex_lock(&list_mutex);
	for (struct facelink_audio *fa = sources; fa; fa = fa->next) {
		pthread_mutex_lock(&fa->mutex);
		// 형식이 바뀌었거나 오래 끊겼다 다시 오면 처음부터
		if (fa->rate != rate || fa->channels != channels || now - fa->last_packet > 500000000ULL)
			ring_reset(fa, rate, channels);
		fa->last_packet = now;

		bool keep = true;
		if (fa->have_sequence) {
			const int32_t diff = (int32_t)(sequence - fa->next_sequence);
			if (diff < 0) {
				keep = false; // 늦게 온 것·중복
				late++;
			} else if (diff > 0) {
				// 잃은 패킷: 그만큼 무음 (100ms까지)
				const size_t gap = (size_t)diff * (size_t)frames;
				const size_t max_gap = frames_for_ms(rate, 100);
				ring_write(fa, NULL, gap < max_gap ? gap : max_gap);
				lost += diff;
			}
		}
		if (keep) {
			ring_write(fa, pcm, (size_t)frames);
			fa->next_sequence = sequence + 1;
			fa->have_sequence = true;
		}
		pthread_mutex_unlock(&fa->mutex);
	}
	pthread_mutex_unlock(&list_mutex);

	pthread_mutex_lock(&stats_mutex);
	if (!stats.receiving)
		blog(LOG_INFO, "[app] facelink audio: receiving %u Hz, %d channel(s)", rate, channels);
	stats.receiving = true;
	stats.sample_rate = rate;
	stats.channels = channels;
	stats.packets++;
	stats.lost += lost;
	stats.late += late;
	pthread_mutex_unlock(&stats_mutex);
}

void core_facelink_audio_get_stats(struct core_facelink_audio_stats *out)
{
	pthread_mutex_lock(&stats_mutex);
	*out = stats;
	pthread_mutex_unlock(&stats_mutex);

	// 버퍼 길이와 끊김은 첫 소스 기준
	pthread_mutex_lock(&list_mutex);
	if (sources) {
		pthread_mutex_lock(&sources->mutex);
		out->buffer_ms = sources->rate ? (int)(sources->count * 1000 / sources->rate) : 0;
		out->sources = 0;
		pthread_mutex_unlock(&sources->mutex);
		for (struct facelink_audio *fa = sources; fa; fa = fa->next)
			out->sources++;
	}
	pthread_mutex_unlock(&list_mutex);
}

void core_facelink_audio_stopped(void)
{
	pthread_mutex_lock(&stats_mutex);
	if (stats.receiving)
		blog(LOG_INFO, "[app] facelink audio: stopped (packets %d, lost %d, late %d, underruns %d)", stats.packets,
		     stats.lost, stats.late, stats.underruns);
	stats.receiving = false;
	pthread_mutex_unlock(&stats_mutex);
}

// 10ms마다 한 덩어리 (지연을 목표 근처로 맞추며)
static void *audio_thread(void *data)
{
	struct facelink_audio *fa = data;
	os_set_thread_name("facelink-audio");
	uint64_t next = os_gettime_ns();

	while (!atomic_load(&fa->stopping)) {
		next += 10000000ULL;
		os_sleepto_ns(next);
		const uint64_t now = os_gettime_ns();
		// 많이 밀렸으면(앱이 멈춤 등) 시계를 다시 맞춘다
		if (now > next + 100000000ULL)
			next = now;

		pthread_mutex_lock(&fa->mutex);
		if (!fa->ring || !fa->rate) {
			pthread_mutex_unlock(&fa->mutex);
			continue;
		}
		const size_t chunk = frames_for_ms(fa->rate, 10);
		const size_t target = frames_for_ms(fa->rate, TARGET_MS);
		bool output = false;
		if (now - fa->last_packet > 500000000ULL) {
			fa->started = false; // 끊김: 무음 (내지 않으면 libobs가 무음으로 둔다)
		} else if (!fa->started) {
			fa->started = fa->count >= target;
		}
		if (fa->started) {
			if (fa->count < chunk) {
				// 모자람: 다시 채운다
				fa->started = false;
				pthread_mutex_lock(&stats_mutex);
				stats.underruns++;
				pthread_mutex_unlock(&stats_mutex);
			} else {
				size_t take = chunk;
				if (fa->count > frames_for_ms(fa->rate, HIGH_MS))
					take = chunk + 1; // 한 표본 버림
				else if (fa->count < frames_for_ms(fa->rate, LOW_MS))
					take = chunk - 1; // 한 표본 늘림
				ring_read(fa, fa->chunk, take);
				if (take == chunk - 1) // 마지막 표본을 한 번 더
					memcpy(fa->chunk + take * fa->channels, fa->chunk + (take - 1) * fa->channels,
					       fa->channels * sizeof(float));
				output = true;
			}
		}
		const uint32_t rate = fa->rate;
		const int channels = fa->channels;
		pthread_mutex_unlock(&fa->mutex);
		if (!output)
			continue;

		// 평면(planar)으로 나눠 낸다
		float planes[MAX_CHANNELS][960 * 2 + 2];
		const size_t frames = chunk < 960 * 2 ? chunk : 960 * 2;
		float peak = 0.0f;
		for (size_t i = 0; i < frames; i++) {
			for (int c = 0; c < channels; c++) {
				planes[c][i] = fa->chunk[i * channels + c];
				peak = fmaxf(peak, fabsf(planes[c][i]));
			}
		}
		// 낸 소리의 최근 피크 (화면·CI): 10ms마다 조금씩 줄인다
		pthread_mutex_lock(&stats_mutex);
		stats.output_peak = fmaxf(peak, stats.output_peak * 0.97f);
		pthread_mutex_unlock(&stats_mutex);
		struct obs_source_audio audio = {
			.frames = (uint32_t)frames,
			.speakers = channels == 2 ? SPEAKERS_STEREO : SPEAKERS_MONO,
			.format = AUDIO_FORMAT_FLOAT_PLANAR,
			.samples_per_sec = rate,
			.timestamp = now,
		};
		for (int c = 0; c < channels; c++)
			audio.data[c] = (const uint8_t *)planes[c];
		obs_source_output_audio(fa->source, &audio);
	}
	return NULL;
}

static const char *facelink_audio_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "아이폰 마이크 (FaceLink)";
}

static void facelink_audio_update(void *data, obs_data_t *settings)
{
	struct facelink_audio *fa = data;
	// 아바타 입 모양과 맞추기: 소리를 늦춘다
	obs_source_set_sync_offset(fa->source, obs_data_get_int(settings, "sync_offset_ms") * 1000000LL);
}

static void *facelink_audio_create(obs_data_t *settings, obs_source_t *source)
{
	struct facelink_audio *fa = bzalloc(sizeof(*fa));
	fa->source = source;
	pthread_mutex_init(&fa->mutex, NULL);
	atomic_init(&fa->stopping, false);
	facelink_audio_update(fa, settings);

	pthread_mutex_lock(&list_mutex);
	fa->next = sources;
	sources = fa;
	pthread_mutex_unlock(&list_mutex);

	fa->thread_running = pthread_create(&fa->thread, NULL, audio_thread, fa) == 0;
	blog(LOG_INFO, "[app] facelink audio: source '%s' created", obs_source_get_name(source));
	return fa;
}

static void facelink_audio_destroy(void *data)
{
	struct facelink_audio *fa = data;

	pthread_mutex_lock(&list_mutex);
	for (struct facelink_audio **link = &sources; *link; link = &(*link)->next) {
		if (*link == fa) {
			*link = fa->next;
			break;
		}
	}
	pthread_mutex_unlock(&list_mutex);

	atomic_store(&fa->stopping, true);
	if (fa->thread_running)
		pthread_join(fa->thread, NULL);
	pthread_mutex_destroy(&fa->mutex);
	bfree(fa->ring);
	bfree(fa->chunk);
	bfree(fa);
}

static void facelink_audio_defaults(obs_data_t *settings)
{
	obs_data_set_default_int(settings, "sync_offset_ms", 0);
}

static obs_properties_t *facelink_audio_properties(void *data)
{
	UNUSED_PARAMETER(data);
	obs_properties_t *props = obs_properties_create();

	struct core_facelink_audio_stats current;
	core_facelink_audio_get_stats(&current);
	char status[256];
	if (current.receiving)
		snprintf(status, sizeof(status), "받는 중: %u Hz %s, 버퍼 %d ms, 잃은 패킷 %d", current.sample_rate,
			 current.channels == 2 ? "스테레오" : "모노", current.buffer_ms, current.lost);
	else
		snprintf(status, sizeof(status),
			 "받지 않는 중: 아이폰 FaceLink 앱에서 소리 보내기를 켜세요 (설정 › 얼굴 추적 › 아이폰에서 받기도 켜져 "
			 "있어야 합니다).");
	obs_properties_add_text(props, "status", status, OBS_TEXT_INFO);
	obs_properties_add_int_slider(props, "sync_offset_ms", "싱크 지연 (ms, 아바타 입 모양과 맞추기)", 0, 500, 10);
	return props;
}

void *core_facelink_audio_test_begin(void)
{
	return obs_source_create_private(FACELINK_AUDIO_SOURCE_ID, "facelink audio test", NULL);
}

void core_facelink_audio_test_end(void *source)
{
	obs_source_release(source);
}

void core_facelink_audio_register(void)
{
	struct obs_source_info info = {
		.id = FACELINK_AUDIO_SOURCE_ID,
		.type = OBS_SOURCE_TYPE_INPUT,
		.output_flags = OBS_SOURCE_AUDIO,
		.get_name = facelink_audio_get_name,
		.create = facelink_audio_create,
		.destroy = facelink_audio_destroy,
		.update = facelink_audio_update,
		.get_defaults = facelink_audio_defaults,
		.get_properties = facelink_audio_properties,
		.icon_type = OBS_ICON_TYPE_AUDIO_INPUT,
	};
	obs_register_source(&info);
}
