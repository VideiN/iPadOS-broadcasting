#include "obs-core.h"

#include <obs.h>
#include <util/bmem.h>

#include <IOSurface/IOSurfaceRef.h>
#include <pthread.h>
#include <string.h>

// 아바타 소스 (P9): VRM 모델은 앱(Avatar.swift)이 RealityKit으로 IOSurface에 그리고, 이 소스는 그것을 텍스처로 보인다.
// 그리기는 앱의 메인 스레드, 보이기는 OBS 그래픽 스레드. 앱이 콜백을 주지 않으면(iOS 18 미만) 등록하지 않는다

#define AVATAR_SOURCE_ID "ios_avatar_source"

struct avatar_source {
	obs_source_t *source;
	void *host; // 앱 쪽 객체 (core_avatar_callbacks.create)
	pthread_mutex_t mutex;
	IOSurfaceRef pending; // 앱이 새로 그린 것. video_tick이 가져간다
	IOSurfaceRef current; // 텍스처가 보이는 것
	gs_texture_t *texture;
	uint32_t width;
	uint32_t height;
};

static struct core_avatar_callbacks avatar_callbacks;
static bool avatar_callbacks_set;

void core_avatar_set_callbacks(const struct core_avatar_callbacks *callbacks)
{
	avatar_callbacks = *callbacks;
	avatar_callbacks_set = true;
}

static void release_surface(IOSurfaceRef surface)
{
	if (!surface)
		return;
	IOSurfaceDecrementUseCount(surface);
	CFRelease(surface);
}

void core_avatar_present(void *context, IOSurfaceRef surface)
{
	struct avatar_source *as = context;
	if (!as || !surface)
		return;

	// 쓰는 동안(use count) 앱은 이 표면에 다시 그리지 않는다
	CFRetain(surface);
	IOSurfaceIncrementUseCount(surface);

	pthread_mutex_lock(&as->mutex);
	IOSurfaceRef old = as->pending;
	as->pending = surface;
	pthread_mutex_unlock(&as->mutex);

	release_surface(old);
}

static const char *avatar_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "VRM Avatar";
}

static void avatar_read_size(struct avatar_source *as, obs_data_t *settings)
{
	as->width = (uint32_t)obs_data_get_int(settings, "width");
	as->height = (uint32_t)obs_data_get_int(settings, "height");
}

static void *avatar_create(obs_data_t *settings, obs_source_t *source)
{
	struct avatar_source *as = bzalloc(sizeof(*as));
	as->source = source;
	pthread_mutex_init(&as->mutex, NULL);
	avatar_read_size(as, settings);
	as->host = avatar_callbacks.create(as, obs_data_get_json_with_defaults(settings));
	return as;
}

static void avatar_destroy(void *data)
{
	struct avatar_source *as = data;

	// 이것이 돌아온 뒤에는 앱이 core_avatar_present를 부르지 않는다
	avatar_callbacks.destroy(as->host);

	obs_enter_graphics();
	gs_texture_destroy(as->texture);
	obs_leave_graphics();

	release_surface(as->pending);
	release_surface(as->current);
	pthread_mutex_destroy(&as->mutex);
	bfree(as);
}

static void avatar_update(void *data, obs_data_t *settings)
{
	struct avatar_source *as = data;
	avatar_read_size(as, settings);
	avatar_callbacks.update(as->host, obs_data_get_json_with_defaults(settings));
}

static void avatar_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "framing", "bust");
	obs_data_set_default_bool(settings, "face_tracking", true);
	obs_data_set_default_bool(settings, "mirror", true);
	obs_data_set_default_int(settings, "width", 1080);
	obs_data_set_default_int(settings, "height", 1080);
	obs_data_set_default_int(settings, "fps", 30);
}

static obs_properties_t *avatar_properties(void *data)
{
	struct avatar_source *as = data;
	obs_properties_t *props = obs_properties_create();

	char status[512] = "";
	if (as)
		avatar_callbacks.copy_status(as->host, status, sizeof(status));
	if (*status)
		obs_properties_add_text(props, "status", status, OBS_TEXT_INFO);

	obs_properties_add_path(props, "model", "VRM 모델", OBS_PATH_FILE, "VRM (*.vrm)", NULL);

	obs_property_t *framing = obs_properties_add_list(props, "framing", "구도", OBS_COMBO_TYPE_LIST,
							  OBS_COMBO_FORMAT_STRING);
	obs_property_list_add_string(framing, "얼굴", "face");
	obs_property_list_add_string(framing, "상반신", "bust");
	obs_property_list_add_string(framing, "전신", "full");

	obs_properties_add_bool(props, "face_tracking", "아이폰 얼굴 추적을 따라 움직이기");
	obs_properties_add_bool(props, "mirror", "거울처럼 움직이기 (고개를 왼쪽으로 돌리면 화면에서도 왼쪽)");

	obs_properties_add_int(props, "width", "너비", 128, 4096, 2);
	obs_properties_add_int(props, "height", "높이", 128, 4096, 2);

	obs_property_t *fps = obs_properties_add_list(props, "fps", "초당 그리기", OBS_COMBO_TYPE_LIST,
						      OBS_COMBO_FORMAT_INT);
	obs_property_list_add_int(fps, "30", 30);
	obs_property_list_add_int(fps, "60", 60);
	return props;
}

static void avatar_show(void *data)
{
	struct avatar_source *as = data;
	avatar_callbacks.set_showing(as->host, true);
}

static void avatar_hide(void *data)
{
	struct avatar_source *as = data;
	avatar_callbacks.set_showing(as->host, false);
}

static void avatar_tick(void *data, float seconds)
{
	UNUSED_PARAMETER(seconds);
	struct avatar_source *as = data;

	pthread_mutex_lock(&as->mutex);
	IOSurfaceRef next = as->pending;
	as->pending = NULL;
	pthread_mutex_unlock(&as->mutex);
	if (!next)
		return;

	obs_enter_graphics();
	if (as->texture)
		gs_texture_rebind_iosurface(as->texture, next);
	else
		as->texture = gs_texture_create_from_iosurface(next);
	obs_leave_graphics();

	release_surface(as->current);
	as->current = next;
}

// 앱이 그린 그림은 투명한 바탕에 미리 곱한 알파(premultiplied)
static void avatar_render(void *data, gs_effect_t *unused)
{
	UNUSED_PARAMETER(unused);
	struct avatar_source *as = data;
	if (!as->texture)
		return;

	gs_effect_t *effect = obs_get_base_effect(OBS_EFFECT_DEFAULT);
	const bool previous = gs_framebuffer_srgb_enabled();
	gs_enable_framebuffer_srgb(true);
	gs_blend_state_push();
	gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);

	gs_effect_set_texture_srgb(gs_effect_get_param_by_name(effect, "image"), as->texture);
	while (gs_effect_loop(effect, "Draw"))
		gs_draw_sprite(as->texture, 0, as->width, as->height);

	gs_blend_state_pop();
	gs_enable_framebuffer_srgb(previous);
}

static uint32_t avatar_width(void *data)
{
	struct avatar_source *as = data;
	return as->width;
}

static uint32_t avatar_height(void *data)
{
	struct avatar_source *as = data;
	return as->height;
}

void core_avatar_register(void)
{
	if (!avatar_callbacks_set) {
		blog(LOG_INFO, "[app] avatar source: not registered (needs iOS 18)");
		return;
	}

	struct obs_source_info info = {
		.id = AVATAR_SOURCE_ID,
		.type = OBS_SOURCE_TYPE_INPUT,
		.output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_CUSTOM_DRAW | OBS_SOURCE_SRGB,
		.get_name = avatar_get_name,
		.create = avatar_create,
		.destroy = avatar_destroy,
		.update = avatar_update,
		.get_defaults = avatar_defaults,
		.get_properties = avatar_properties,
		.show = avatar_show,
		.hide = avatar_hide,
		.video_tick = avatar_tick,
		.video_render = avatar_render,
		.get_width = avatar_width,
		.get_height = avatar_height,
	};
	obs_register_source(&info);
}
