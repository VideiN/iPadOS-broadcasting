/* iOS port: smoke test for the static libobs build.
 *
 * Runs on the iOS simulator without a graphics device and checks the parts
 * that do not need one: startup/shutdown, settings (jansson), the FFmpeg-based
 * audio resampler and video scaler, static module registration and the scene
 * graph. */

#include <obs.h>
#include <media-io/audio-resampler.h>
#include <media-io/video-scaler.h>
#include <util/bmem.h>

#include <stdio.h>
#include <string.h>

extern const struct obs_static_module obs_static_module_test_input;

static int failures = 0;

#define CHECK(expr)                                                                   \
	do {                                                                          \
		if (expr) {                                                           \
			printf("ok   - %s\n", #expr);                                 \
		} else {                                                              \
			printf("FAIL - %s (%s:%d)\n", #expr, __FILE__, __LINE__);     \
			failures++;                                                   \
		}                                                                     \
	} while (0)

static void test_data(void)
{
	obs_data_t *data = obs_data_create();
	obs_data_set_string(data, "name", "ipad");
	obs_data_set_int(data, "fps", 60);

	obs_data_t *parsed = obs_data_create_from_json(obs_data_get_json(data));
	CHECK(parsed != NULL);
	if (parsed) {
		CHECK(strcmp(obs_data_get_string(parsed, "name"), "ipad") == 0);
		CHECK(obs_data_get_int(parsed, "fps") == 60);
		obs_data_release(parsed);
	}

	obs_data_release(data);
}

static void test_audio_resampler(void)
{
	const struct resample_info src = {
		.samples_per_sec = 44100,
		.format = AUDIO_FORMAT_FLOAT_PLANAR,
		.speakers = SPEAKERS_STEREO,
	};
	const struct resample_info dst = {
		.samples_per_sec = 48000,
		.format = AUDIO_FORMAT_FLOAT_PLANAR,
		.speakers = SPEAKERS_STEREO,
	};

	audio_resampler_t *resampler = audio_resampler_create(&dst, &src);
	CHECK(resampler != NULL);
	if (!resampler)
		return;

	static float left[4410];
	static float right[4410];
	const uint8_t *input[MAX_AV_PLANES] = {(const uint8_t *)left, (const uint8_t *)right};
	uint8_t *output[MAX_AV_PLANES] = {0};
	uint32_t out_frames = 0;
	uint64_t ts_offset = 0;

	bool ok = audio_resampler_resample(resampler, output, &out_frames, &ts_offset, input, 4410);
	CHECK(ok);
	CHECK(out_frames > 0);

	audio_resampler_destroy(resampler);
}

static void test_video_scaler(void)
{
	const struct video_scale_info src = {
		.format = VIDEO_FORMAT_NV12,
		.width = 64,
		.height = 64,
		.range = VIDEO_RANGE_PARTIAL,
		.colorspace = VIDEO_CS_709,
	};
	const struct video_scale_info dst = {
		.format = VIDEO_FORMAT_BGRA,
		.width = 32,
		.height = 32,
		.range = VIDEO_RANGE_FULL,
		.colorspace = VIDEO_CS_709,
	};

	video_scaler_t *scaler = NULL;
	CHECK(video_scaler_create(&scaler, &dst, &src, VIDEO_SCALE_BILINEAR) == VIDEO_SCALER_SUCCESS);
	if (!scaler)
		return;

	static uint8_t luma[64 * 64];
	static uint8_t chroma[64 * 32];
	static uint8_t bgra[32 * 32 * 4];
	const uint8_t *input[] = {luma, chroma};
	const uint32_t in_linesize[] = {64, 64};
	uint8_t *output[] = {bgra};
	const uint32_t out_linesize[] = {32 * 4};

	memset(luma, 235, sizeof(luma));
	memset(chroma, 128, sizeof(chroma));

	CHECK(video_scaler_scale(scaler, output, out_linesize, input, in_linesize));
	CHECK(bgra[0] > 200 && bgra[1] > 200 && bgra[2] > 200);

	video_scaler_destroy(scaler);
}

static void test_static_module_and_scene(void)
{
	obs_module_t *module = NULL;
	CHECK(obs_open_static_module(&module, &obs_static_module_test_input, NULL) == MODULE_SUCCESS);
	CHECK(module != NULL);
	if (!module)
		return;

	CHECK(obs_init_module(module));
	obs_post_load_modules();

	CHECK(strcmp(obs_get_module_file_name(module), "test-input") == 0);
	CHECK(obs_get_module("test-input") == module);
	CHECK(obs_source_get_display_name("test_sinewave") != NULL);

	obs_scene_t *scene = obs_scene_create("Scene");
	CHECK(scene != NULL);
	obs_source_t *source = obs_source_create("test_sinewave", "Sine", NULL, NULL);
	CHECK(source != NULL);

	if (scene && source) {
		obs_sceneitem_t *item = obs_scene_add(scene, source);
		CHECK(item != NULL);
		CHECK(obs_scene_find_source(scene, "Sine") == item);
	}

	obs_source_release(source);
	obs_scene_release(scene);
}

int main(void)
{
	CHECK(obs_startup("en-US", NULL, NULL));
	if (!obs_initialized()) {
		printf("FAILED: obs_startup\n");
		return 1;
	}
	printf("libobs %s\n", obs_get_version_string());

	const struct obs_audio_info audio_info = {
		.samples_per_sec = 48000,
		.speakers = SPEAKERS_STEREO,
	};
	CHECK(obs_reset_audio(&audio_info));

	test_data();
	test_audio_resampler();
	test_video_scaler();
	test_static_module_and_scene();

	obs_shutdown();
	printf("memory leaks: %ld\n", bnum_allocs());

	if (failures) {
		printf("FAILED: %d check(s)\n", failures);
		return 1;
	}

	printf("ALL TESTS PASSED\n");
	return 0;
}
