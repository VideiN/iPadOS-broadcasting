#include "obs-core.h"

#include <obs.h>
#include <graphics/vec2.h>
#include <util/dstr.h>

#include <math.h>
#include <mach/mach.h>
#include <os/proc.h>

// 정적으로 링크한 모듈 (obs_ios_static_module, libobs-metal의 CMake가 생성)
extern const struct obs_static_module obs_static_module_image_source;
extern void *libobs_metal_get_export(const char *symbol);
extern double libobs_metal_gpu_busy_ms_per_second(void);

static struct {
	uint32_t width;
	uint32_t height;
	double fps;
	obs_scene_t *scene;
	obs_sceneitem_t *moving_bar;
	float elapsed;
} core;

static obs_source_t *create_color_source(const char *name, uint32_t abgr, uint32_t width, uint32_t height)
{
	obs_data_t *settings = obs_data_create();
	obs_data_set_int(settings, "color", abgr);
	obs_data_set_int(settings, "width", width);
	obs_data_set_int(settings, "height", height);

	obs_source_t *source = obs_source_create("color_source_v3", name, settings, NULL);
	obs_data_release(settings);
	return source;
}

static void add_to_scene(obs_source_t *source, obs_sceneitem_t **item)
{
	if (!source)
		return;

	obs_sceneitem_t *added = obs_scene_add(core.scene, source);
	if (item)
		*item = added;
	obs_source_release(source);
}

// 프레임마다 막대를 좌우로 움직인다. 프리뷰가 실제로 갱신되는지, ProMotion에서 프레임 간격이 고른지 눈으로 확인하는 용도.
static void move_bar(void *param, float seconds)
{
	UNUSED_PARAMETER(param);

	if (!core.moving_bar)
		return;

	core.elapsed += seconds;

	const float bar_width = 40.0f;
	struct vec2 pos;
	pos.x = (sinf(core.elapsed * 2.0f) * 0.5f + 0.5f) * ((float)core.width - bar_width);
	pos.y = 0.0f;
	obs_sceneitem_set_pos(core.moving_bar, &pos);
}

static bool load_modules(const char *resource_path)
{
	struct dstr data_path = {0};
	dstr_printf(&data_path, "%s/obs-plugins/image-source", resource_path);

	obs_module_t *module = NULL;
	int ret = obs_open_static_module(&module, &obs_static_module_image_source, data_path.array);
	dstr_free(&data_path);

	if (ret != MODULE_SUCCESS || !obs_init_module(module)) {
		blog(LOG_ERROR, "[app] failed to load image-source (%d)", ret);
		return false;
	}

	obs_post_load_modules();
	return true;
}

static bool reset_video(uint32_t width, uint32_t height, uint32_t fps)
{
	struct obs_video_info ovi = {
		.graphics_module = "libobs-metal",
		.fps_num = fps,
		.fps_den = 1,
		.base_width = width,
		.base_height = height,
		.output_width = width,
		.output_height = height,
		.output_format = VIDEO_FORMAT_NV12,
		.adapter = 0,
		.gpu_conversion = true,
		.colorspace = VIDEO_CS_709,
		.range = VIDEO_RANGE_PARTIAL,
		.scale_type = OBS_SCALE_BICUBIC,
	};

	int ret = obs_reset_video(&ovi);
	if (ret != OBS_VIDEO_SUCCESS) {
		blog(LOG_ERROR, "[app] obs_reset_video failed (%d)", ret);
		return false;
	}

	return true;
}

static void create_test_scene(const char *resource_path)
{
	core.scene = obs_scene_create("Scene");

	add_to_scene(create_color_source("Background", 0xFF3A2414, core.width, core.height), NULL);

	struct dstr file = {0};
	dstr_printf(&file, "%s/test-pattern.png", resource_path);
	obs_data_t *settings = obs_data_create();
	obs_data_set_string(settings, "file", file.array);
	obs_source_t *image = obs_source_create("image_source", "Test Pattern", settings, NULL);
	obs_data_release(settings);
	dstr_free(&file);

	// 캔버스 가운데에 80% 크기로 맞춘다
	obs_sceneitem_t *image_item = NULL;
	add_to_scene(image, &image_item);
	if (image_item) {
		struct vec2 bounds = {core.width * 0.8f, core.height * 0.8f};
		struct vec2 pos = {core.width * 0.5f, core.height * 0.5f};
		obs_sceneitem_set_bounds_type(image_item, OBS_BOUNDS_SCALE_INNER);
		obs_sceneitem_set_bounds(image_item, &bounds);
		obs_sceneitem_set_bounds_alignment(image_item, OBS_ALIGN_CENTER);
		obs_sceneitem_set_alignment(image_item, OBS_ALIGN_CENTER);
		obs_sceneitem_set_pos(image_item, &pos);
	}

	add_to_scene(create_color_source("Moving Bar", 0xFFFFFFFF, 40, core.height), &core.moving_bar);
	obs_add_tick_callback(move_bar, NULL);

	obs_set_output_source(0, obs_scene_get_source(core.scene));
}

bool core_startup(const char *resource_path, uint32_t width, uint32_t height, uint32_t fps)
{
	core.width = width;
	core.height = height;
	core.fps = fps;

	gs_register_static_module("libobs-metal", libobs_metal_get_export);

	if (!obs_startup("en-US", NULL, NULL)) {
		blog(LOG_ERROR, "[app] obs_startup failed");
		return false;
	}

	if (!load_modules(resource_path))
		return false;

	const struct obs_audio_info audio = {
		.samples_per_sec = 48000,
		.speakers = SPEAKERS_STEREO,
	};
	obs_reset_audio(&audio);

	if (!reset_video(width, height, fps))
		return false;

	create_test_scene(resource_path);

	blog(LOG_INFO, "[app] core started (%ux%u @ %u fps)", width, height, fps);
	return true;
}

// 캔버스를 화면비를 유지한 채 디스플레이에 맞춰 그린다
static void render_preview(void *param, uint32_t cx, uint32_t cy)
{
	UNUSED_PARAMETER(param);

	struct obs_video_info ovi;
	if (!obs_get_video_info(&ovi))
		return;

	const float scale = fminf((float)cx / ovi.base_width, (float)cy / ovi.base_height);
	const int width = (int)(ovi.base_width * scale);
	const int height = (int)(ovi.base_height * scale);
	const int x = ((int)cx - width) / 2;
	const int y = ((int)cy - height) / 2;

	gs_viewport_push();
	gs_projection_push();
	gs_ortho(0.0f, (float)ovi.base_width, 0.0f, (float)ovi.base_height, -100.0f, 100.0f);
	gs_set_viewport(x, y, width, height);

	obs_render_main_texture();

	gs_projection_pop();
	gs_viewport_pop();
}

void *core_display_create(void *view, uint32_t width, uint32_t height)
{
	struct gs_init_data info = {0};
	info.cx = width;
	info.cy = height;
	info.format = GS_BGRA;
	info.zsformat = GS_ZS_NONE;
	info.window.view = (id)view;

	obs_display_t *display = obs_display_create(&info, 0xFF000000);
	if (!display) {
		blog(LOG_ERROR, "[app] obs_display_create failed");
		return NULL;
	}

	obs_display_add_draw_callback(display, render_preview, NULL);
	return display;
}

void core_display_resize(void *display, uint32_t width, uint32_t height)
{
	obs_display_resize(display, width, height);
}

void core_display_destroy(void *display)
{
	obs_display_remove_draw_callback(display, render_preview, NULL);
	obs_display_destroy(display);
}

void core_get_stats(struct core_stats *stats)
{
	stats->active_fps = obs_get_active_fps();
	stats->target_fps = core.fps;
	stats->frame_time_ms = (double)obs_get_average_frame_time_ns() / 1000000.0;
	stats->gpu_ms_per_second = libobs_metal_gpu_busy_ms_per_second();
	stats->total_frames = obs_get_total_frames();
	stats->lagged_frames = obs_get_lagged_frames();

	task_vm_info_data_t vm_info = {0};
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm_info, &count) == KERN_SUCCESS)
		stats->memory_footprint = vm_info.phys_footprint;
	else
		stats->memory_footprint = 0;

	stats->memory_available = os_proc_available_memory();
}
