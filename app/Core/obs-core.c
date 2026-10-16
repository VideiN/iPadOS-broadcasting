#include "obs-core.h"
#include "capture-format.h"
#include "crash-log.h"

#include <obs.h>
#include <graphics/vec2.h>
#include <util/dstr.h>
#include <util/platform.h>

#include <math.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/time.h>
#include <time.h>

// 정적으로 링크한 모듈 (obs_ios_static_module, libobs-metal의 CMake가 생성)
extern const struct obs_static_module obs_static_module_image_source;
extern const struct obs_static_module obs_static_module_mac_avcapture;
extern const struct obs_static_module obs_static_module_ios_audio_input;
extern const struct obs_static_module obs_static_module_mac_videotoolbox;
extern const struct obs_static_module obs_static_module_coreaudio_encoder;
extern const struct obs_static_module obs_static_module_obs_outputs;

// outputs.c
extern void core_outputs_register(void);
extern void *libobs_metal_get_export(const char *symbol);
extern double libobs_metal_gpu_busy_ms_per_second(void);

static struct {
	uint32_t width;
	uint32_t height;
	double fps;
	obs_scene_t *scene;
	obs_sceneitem_t *moving_bar;
	float elapsed;

	obs_source_t *camera;
	obs_source_t *audio_input;
	obs_volmeter_t *volmeter;
	_Atomic float audio_peak_left_db;
	_Atomic float audio_peak_right_db;
	_Atomic uint64_t audio_peak_time; // os_gettime_ns
} core = {.audio_peak_left_db = -INFINITY, .audio_peak_right_db = -INFINITY};

#pragma mark - 로그

// 기기에서는 표준 출력을 볼 수 없어서 Documents의 파일에도 남긴다 (파일 앱에서 열람)
static struct {
	pthread_mutex_t mutex;
	FILE *file;
} log_file = {.mutex = PTHREAD_MUTEX_INITIALIZER};

static const char *log_level_name(int level)
{
	if (level <= LOG_ERROR)
		return "error";
	if (level <= LOG_WARNING)
		return "warning";
	if (level <= LOG_INFO)
		return "info";
	return "debug";
}

static void log_handler(int level, const char *format, va_list args, void *param)
{
	UNUSED_PARAMETER(param);

	if (level > LOG_INFO)
		return;

	char message[8192];
	vsnprintf(message, sizeof(message), format, args);

	fprintf(stdout, "%s: %s\n", log_level_name(level), message);
	fflush(stdout);

	struct timeval now;
	gettimeofday(&now, NULL);
	struct tm local;
	localtime_r(&now.tv_sec, &local);
	char clock[16];
	strftime(clock, sizeof(clock), "%H:%M:%S", &local);

	pthread_mutex_lock(&log_file.mutex);
	if (log_file.file) {
		fprintf(log_file.file, "%s.%03d %s: %s\n", clock, (int)(now.tv_usec / 1000), log_level_name(level),
			message);
		fflush(log_file.file);
	}
	pthread_mutex_unlock(&log_file.mutex);
}

void core_log_open(const char *path)
{
	struct dstr previous = {0};
	dstr_printf(&previous, "%s.prev", path);
	rename(path, previous.array);
	dstr_free(&previous);

	pthread_mutex_lock(&log_file.mutex);
	log_file.file = fopen(path, "w");
	pthread_mutex_unlock(&log_file.mutex);

	// 크래시가 나면 스택을 같은 파일에 남긴다 (기기에서 원인을 찾을 수 있게)
	crash_log_install(log_file.file ? fileno(log_file.file) : -1);

	base_set_log_handler(log_handler, NULL);
	blog(LOG_INFO, "[app] log file: %s", log_file.file ? path : "(failed to open)");
}

void core_log(const char *message)
{
	blog(LOG_INFO, "%s", message);
}

#pragma mark - 씬

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

// 소스를 캔버스 안에 화면비를 유지해 맞춘다
static void fit_item(obs_sceneitem_t *item, float scale)
{
	struct vec2 bounds = {core.width * scale, core.height * scale};
	struct vec2 pos = {core.width * 0.5f, core.height * 0.5f};
	obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_SCALE_INNER);
	obs_sceneitem_set_bounds(item, &bounds);
	obs_sceneitem_set_bounds_alignment(item, OBS_ALIGN_CENTER);
	obs_sceneitem_set_alignment(item, OBS_ALIGN_CENTER);
	obs_sceneitem_set_pos(item, &pos);
}

// 프레임마다 막대를 좌우로 움직인다. 프리뷰가 실제로 갱신되는지, ProMotion에서 프레임 간격이 고른지 눈으로 확인하는 용도.
// 카메라를 가리지 않게 화면 아래쪽에 짧게 둔다.
static const float bar_width = 40.0f;
static const float bar_height = 60.0f;

static void move_bar(void *param, float seconds)
{
	UNUSED_PARAMETER(param);

	if (!core.moving_bar)
		return;

	core.elapsed += seconds;

	struct vec2 pos;
	pos.x = (sinf(core.elapsed * 2.0f) * 0.5f + 0.5f) * ((float)core.width - bar_width);
	pos.y = (float)core.height - bar_height;
	obs_sceneitem_set_pos(core.moving_bar, &pos);
}

static bool load_module(const char *resource_path, const char *name, const struct obs_static_module *static_module)
{
	struct dstr data_path = {0};
	dstr_printf(&data_path, "%s/obs-plugins/%s", resource_path, name);

	obs_module_t *module = NULL;
	int ret = obs_open_static_module(&module, static_module, data_path.array);
	dstr_free(&data_path);

	if (ret != MODULE_SUCCESS || !obs_init_module(module)) {
		blog(LOG_ERROR, "[app] failed to load %s (%d)", name, ret);
		return false;
	}

	return true;
}

static bool load_modules(const char *resource_path)
{
	if (!load_module(resource_path, "image-source", &obs_static_module_image_source))
		return false;

	// 입력·출력 모듈은 실패해도 테스트 씬은 띄운다
	load_module(resource_path, "mac-avcapture", &obs_static_module_mac_avcapture);
	load_module(resource_path, "ios-audio-input", &obs_static_module_ios_audio_input);
	load_module(resource_path, "mac-videotoolbox", &obs_static_module_mac_videotoolbox);
	load_module(resource_path, "coreaudio-encoder", &obs_static_module_coreaudio_encoder);
	load_module(resource_path, "obs-outputs", &obs_static_module_obs_outputs);

	// VideoToolbox 인코더는 post_load에서 등록된다
	obs_post_load_modules();
	core_outputs_register();

	const char *id;
	for (size_t i = 0; obs_enum_encoder_types(i, &id); i++)
		blog(LOG_INFO, "[app] encoder: %s (%s)", id, obs_get_encoder_codec(id));

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

	// 캔버스 가운데에 80% 크기로 맞춘다. 카메라가 없을 때 보인다.
	obs_sceneitem_t *image_item = NULL;
	add_to_scene(image, &image_item);
	if (image_item)
		fit_item(image_item, 0.8f);

	obs_set_output_source(0, obs_scene_get_source(core.scene));
}

static void add_moving_bar(void)
{
	add_to_scene(create_color_source("Moving Bar", 0xFFFFFFFF, (uint32_t)bar_width, (uint32_t)bar_height),
		     &core.moving_bar);
	obs_add_tick_callback(move_bar, NULL);
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
	add_moving_bar();

	blog(LOG_INFO, "[app] core started (%ux%u @ %u fps)", width, height, fps);
	return true;
}

#pragma mark - 카메라·오디오 입력

static void volmeter_updated(void *param, const float magnitude[MAX_AUDIO_CHANNELS],
			     const float peak[MAX_AUDIO_CHANNELS], const float input_peak[MAX_AUDIO_CHANNELS])
{
	UNUSED_PARAMETER(param);
	UNUSED_PARAMETER(magnitude);
	UNUSED_PARAMETER(input_peak);

	// 출력 오디오가 스테레오라 볼륨미터는 소스를 L/R로 올려서 잰다 (모노 입력이면 두 값이 같다)
	audio_t *audio = obs_get_audio();
	const bool stereo = audio && audio_output_get_channels(audio) > 1;

	atomic_store(&core.audio_peak_left_db, peak[0]);
	atomic_store(&core.audio_peak_right_db, stereo ? peak[1] : peak[0]);
	atomic_store(&core.audio_peak_time, os_gettime_ns());
}

void core_start_capture(void)
{
	if (core.camera || core.audio_input)
		return;

	// 카메라: 캔버스 전체에 맞추고 움직이는 막대 아래에 둔다
	char *camera_id = capture_default_camera_id();
	obs_data_t *settings = obs_data_create();
	capture_configure_camera(settings, camera_id, core.width, core.height, (uint32_t)core.fps);
	core.camera = obs_source_create("macos-avcapture", "Camera", settings, NULL);
	obs_data_release(settings);

	if (core.camera) {
		obs_sceneitem_t *item = obs_scene_add(core.scene, core.camera);
		if (item) {
			fit_item(item, 1.0f);
			if (core.moving_bar)
				obs_sceneitem_set_order(core.moving_bar, OBS_ORDER_MOVE_TOP);
		}
	}

	// 오디오 입력: 출력 채널 1에 걸어 믹서에 들어가게 한다
	core.audio_input = obs_source_create("ios_audio_input", "Audio Input", NULL, NULL);
	if (core.audio_input) {
		obs_set_output_source(1, core.audio_input);

		core.volmeter = obs_volmeter_create(OBS_FADER_LOG);
		obs_volmeter_add_callback(core.volmeter, volmeter_updated, NULL);
		obs_volmeter_attach_source(core.volmeter, core.audio_input);
	}

	blog(LOG_INFO, "[app] capture started (camera: %s, audio input: %s)", core.camera ? "yes" : "no",
	     core.audio_input ? "yes" : "no");
	bfree(camera_id);
}

static obs_source_t *device_source(enum core_device_kind kind)
{
	return kind == CORE_DEVICE_CAMERA ? core.camera : core.audio_input;
}

char *core_list_devices(enum core_device_kind kind)
{
	obs_source_t *source = device_source(kind);
	if (!source)
		return NULL;

	obs_properties_t *props = obs_source_properties(source);
	obs_property_t *list = obs_properties_get(props, "device");

	struct dstr out = {0};
	dstr_copy(&out, "");

	size_t count = list ? obs_property_list_item_count(list) : 0;
	for (size_t i = 0; i < count; i++) {
		const char *id = obs_property_list_item_string(list, i);
		const char *name = obs_property_list_item_name(list, i);

		// 카메라의 빈 항목("선택 안 함")은 빼고, 오디오의 빈 id는 시스템 기본 경로라 남긴다.
		// 비활성 항목은 지금 고른 장치가 빠져 있는 경우다. 마지막으로 알던 이름으로 남겨 0을 붙인다.
		if (!id || (kind == CORE_DEVICE_CAMERA && !*id))
			continue;

		const bool available = !obs_property_list_item_disabled(list, i);
		dstr_catf(&out, "%s\t%s\t%d\n", id, name ? name : id, available ? 1 : 0);
	}

	obs_properties_destroy(props);
	return out.array;
}

char *core_current_device(enum core_device_kind kind)
{
	obs_source_t *source = device_source(kind);
	if (!source)
		return NULL;

	obs_data_t *settings = obs_source_get_settings(source);
	char *id = bstrdup(obs_data_get_string(settings, "device"));
	obs_data_release(settings);
	return id;
}

void core_select_device(enum core_device_kind kind, const char *device_id)
{
	obs_source_t *source = device_source(kind);
	if (!source)
		return;

	obs_data_t *settings = obs_source_get_settings(source);

	if (kind == CORE_DEVICE_CAMERA)
		capture_configure_camera(settings, device_id, core.width, core.height, (uint32_t)core.fps);
	else
		obs_data_set_string(settings, "device", device_id ? device_id : "");

	obs_source_update(source, settings);
	obs_data_release(settings);

	blog(LOG_INFO, "[app] selected %s device '%s'", kind == CORE_DEVICE_CAMERA ? "camera" : "audio input",
	     device_id ? device_id : "");
}

void core_free(void *ptr)
{
	bfree(ptr);
}

#pragma mark - 프리뷰

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

#pragma mark - 계측

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

	stats->camera_width = core.camera ? obs_source_get_width(core.camera) : 0;
	stats->camera_height = core.camera ? obs_source_get_height(core.camera) : 0;
	// 오디오가 1초 넘게 안 들어오면 무음으로 표시한다
	const bool audio_stale = os_gettime_ns() - atomic_load(&core.audio_peak_time) > 1000000000ULL;
	stats->audio_peak_left_db = audio_stale ? -INFINITY : atomic_load(&core.audio_peak_left_db);
	stats->audio_peak_right_db = audio_stale ? -INFINITY : atomic_load(&core.audio_peak_right_db);
}
