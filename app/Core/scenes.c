// 씬·소스 관리와 씬 구성 저장·불러오기 (P4)
//
// Swift에는 씬은 이름으로, 씬 항목은 obs_sceneitem_get_id로, 소스는 이름으로 넘긴다 (이름은 겹치지 않게 만든다).
// 목록·속성처럼 모양이 복잡한 값은 obs_data로 JSON을 만들어 넘긴다.

#include "obs-core.h"
#include "scenes.h"
#include "capture-format.h"

#include <obs.h>
#include <graphics/matrix4.h>
#include <graphics/vec3.h>
#include <util/darray.h>
#include <util/dstr.h>

#include <math.h>
#include <pthread.h>
#include <string.h>

#define CAMERA_SOURCE_ID "macos-avcapture"
#define AUDIO_INPUT_SOURCE_ID "ios_audio_input"
#define FILTER_SEPARATOR 0x1F // 필터 이름: "소스" + 0x1F + "필터" (Swift에서는 "\u{1F}")

// 씬 목록(표시 순서). 목록이 각 씬의 참조를 가진다.
static struct {
	pthread_mutex_t mutex;
	DARRAY(obs_source_t *) scenes;
	obs_source_t *current; // 목록 안의 씬 (참조는 목록이 가짐)
} sc = {.mutex = PTHREAD_MUTEX_INITIALIZER};

static void canvas_size(uint32_t *width, uint32_t *height)
{
	struct obs_video_info ovi;
	if (obs_get_video_info(&ovi)) {
		*width = ovi.base_width;
		*height = ovi.base_height;
	} else {
		*width = 1920;
		*height = 1080;
	}
}

static char *json_from(obs_data_t *data)
{
	char *json = bstrdup(obs_data_get_json(data));
	obs_data_release(data);
	return json;
}

// 소스 이름으로 찾는다. "소스\x1F필터"면 그 소스의 필터를 찾는다 (속성 편집기가 필터에도 쓰인다). 참조를 돌려준다.
static obs_source_t *find_source(const char *name)
{
	const char *separator = name ? strchr(name, FILTER_SEPARATOR) : NULL;
	if (!separator)
		return obs_get_source_by_name(name);

	char *parent_name = bstrdup_n(name, separator - name);
	obs_source_t *parent = obs_get_source_by_name(parent_name);
	bfree(parent_name);
	if (!parent)
		return NULL;

	obs_source_t *filter = obs_source_get_filter_by_name(parent, separator + 1);
	obs_source_release(parent);
	return filter;
}

// base, "base 2", "base 3", … 중 아직 없는 이름
static char *unique_source_name(const char *base)
{
	struct dstr name = {0};
	dstr_copy(&name, base);

	for (int i = 2;; i++) {
		obs_source_t *existing = obs_get_source_by_name(name.array);
		if (!existing)
			break;
		obs_source_release(existing);
		dstr_printf(&name, "%s %d", base, i);
	}
	return name.array;
}

#pragma mark - 씬

static obs_scene_t *current_scene(void)
{
	return sc.current ? obs_scene_from_source(sc.current) : NULL;
}

static obs_source_t *find_scene_locked(const char *name)
{
	for (size_t i = 0; i < sc.scenes.num; i++) {
		if (strcmp(obs_source_get_name(sc.scenes.array[i]), name) == 0)
			return sc.scenes.array[i];
	}
	return NULL;
}

static void set_current_locked(obs_source_t *scene)
{
	sc.current = scene;
	obs_set_output_source(0, scene);
}

// 새 씬 (목록에 넣고 참조는 목록이 가진다)
static obs_scene_t *add_scene_locked(const char *base_name)
{
	char *name = unique_source_name(base_name);
	obs_scene_t *scene = obs_scene_create(name);
	bfree(name);

	if (scene)
		da_push_back(sc.scenes, &(obs_source_t *){obs_scene_get_source(scene)});
	return scene;
}

char *core_scenes_json(void)
{
	obs_data_t *root = obs_data_create();
	obs_data_array_t *scenes = obs_data_array_create();

	pthread_mutex_lock(&sc.mutex);
	for (size_t i = 0; i < sc.scenes.num; i++) {
		obs_data_t *item = obs_data_create();
		obs_data_set_string(item, "name", obs_source_get_name(sc.scenes.array[i]));
		obs_data_array_push_back(scenes, item);
		obs_data_release(item);
	}
	obs_data_set_string(root, "current", sc.current ? obs_source_get_name(sc.current) : "");
	pthread_mutex_unlock(&sc.mutex);

	obs_data_set_array(root, "scenes", scenes);
	obs_data_array_release(scenes);
	return json_from(root);
}

bool core_scene_add(const char *name)
{
	pthread_mutex_lock(&sc.mutex);
	obs_scene_t *scene = add_scene_locked(name && *name ? name : "장면");
	if (scene)
		set_current_locked(obs_scene_get_source(scene));
	pthread_mutex_unlock(&sc.mutex);
	return scene != NULL;
}

bool core_scene_remove(const char *name)
{
	pthread_mutex_lock(&sc.mutex);

	// 씬은 하나 이상 남긴다
	obs_source_t *scene = find_scene_locked(name);
	if (!scene || sc.scenes.num < 2) {
		pthread_mutex_unlock(&sc.mutex);
		return false;
	}

	size_t index = da_find(sc.scenes, &scene, 0);
	da_erase(sc.scenes, index);
	if (sc.current == scene)
		set_current_locked(sc.scenes.array[index < sc.scenes.num ? index : sc.scenes.num - 1]);

	pthread_mutex_unlock(&sc.mutex);

	obs_source_remove(scene);
	obs_source_release(scene);
	return true;
}

bool core_scene_rename(const char *name, const char *new_name)
{
	if (!new_name || !*new_name)
		return false;

	obs_source_t *existing = obs_get_source_by_name(new_name);
	if (existing) {
		obs_source_release(existing);
		return false;
	}

	pthread_mutex_lock(&sc.mutex);
	obs_source_t *scene = find_scene_locked(name);
	if (scene)
		obs_source_set_name(scene, new_name);
	pthread_mutex_unlock(&sc.mutex);
	return scene != NULL;
}

void core_scene_set_current(const char *name)
{
	pthread_mutex_lock(&sc.mutex);
	obs_source_t *scene = find_scene_locked(name);
	if (scene)
		set_current_locked(scene);
	pthread_mutex_unlock(&sc.mutex);
}

void core_scene_move(const char *name, int offset)
{
	pthread_mutex_lock(&sc.mutex);
	obs_source_t *scene = find_scene_locked(name);
	if (scene) {
		size_t index = da_find(sc.scenes, &scene, 0);
		long target = (long)index + offset;
		if (target >= 0 && (size_t)target < sc.scenes.num)
			da_move_item(sc.scenes, index, (size_t)target);
	}
	pthread_mutex_unlock(&sc.mutex);
}

#pragma mark - 씬 항목

struct item_list {
	DARRAY(obs_sceneitem_t *) items;
};

static bool collect_item(obs_scene_t *scene, obs_sceneitem_t *item, void *param)
{
	UNUSED_PARAMETER(scene);
	struct item_list *list = param;
	obs_sceneitem_addref(item);
	da_push_back(list->items, &item);
	return true;
}

// 현재 씬의 항목을 맨 아래부터 (참조를 더해서) 모은다
static void collect_items(struct item_list *list)
{
	da_init(list->items);

	pthread_mutex_lock(&sc.mutex);
	obs_scene_t *scene = current_scene();
	if (scene)
		obs_scene_enum_items(scene, collect_item, list);
	pthread_mutex_unlock(&sc.mutex);
}

static void free_items(struct item_list *list)
{
	for (size_t i = 0; i < list->items.num; i++)
		obs_sceneitem_release(list->items.array[i]);
	da_free(list->items);
}

// 현재 씬의 항목 (참조를 더해 돌려준다. obs_sceneitem_release로 놓는다)
static obs_sceneitem_t *find_item(int64_t id)
{
	pthread_mutex_lock(&sc.mutex);
	obs_scene_t *scene = current_scene();
	obs_sceneitem_t *item = scene ? obs_scene_find_sceneitem_by_id(scene, id) : NULL;
	if (item)
		obs_sceneitem_addref(item);
	pthread_mutex_unlock(&sc.mutex);
	return item;
}

static void item_box(obs_sceneitem_t *item, struct vec3 corners[4])
{
	struct matrix4 transform;
	obs_sceneitem_get_box_transform(item, &transform);

	const float unit[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
	for (int i = 0; i < 4; i++) {
		vec3_set(&corners[i], unit[i][0], unit[i][1], 0.0f);
		vec3_transform(&corners[i], &corners[i], &transform);
	}
}

char *core_scene_items_json(void)
{
	struct item_list list;
	collect_items(&list);

	obs_data_t *root = obs_data_create();
	obs_data_array_t *items = obs_data_array_create();

	// 위에 있는 항목부터
	for (size_t i = list.items.num; i > 0; i--) {
		obs_sceneitem_t *item = list.items.array[i - 1];
		obs_source_t *source = obs_sceneitem_get_source(item);
		const uint32_t flags = obs_source_get_output_flags(source);

		obs_data_t *entry = obs_data_create();
		obs_data_set_int(entry, "id", obs_sceneitem_get_id(item));
		obs_data_set_string(entry, "name", obs_source_get_name(source));
		obs_data_set_string(entry, "type", obs_source_get_id(source));
		obs_data_set_bool(entry, "visible", obs_sceneitem_visible(item));
		obs_data_set_bool(entry, "locked", obs_sceneitem_locked(item));
		obs_data_set_bool(entry, "video", (flags & OBS_SOURCE_VIDEO) != 0);
		obs_data_set_bool(entry, "audio", (flags & OBS_SOURCE_AUDIO) != 0);
		obs_data_array_push_back(items, entry);
		obs_data_release(entry);
	}

	free_items(&list);

	obs_data_set_array(root, "items", items);
	obs_data_array_release(items);
	return json_from(root);
}

bool core_scene_item_box(int64_t id, float corners[8])
{
	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return false;

	struct vec3 box[4];
	item_box(item, box);
	for (int i = 0; i < 4; i++) {
		corners[i * 2] = box[i].x;
		corners[i * 2 + 1] = box[i].y;
	}
	obs_sceneitem_release(item);
	return true;
}

int64_t core_scene_item_at(float x, float y)
{
	struct item_list list;
	collect_items(&list);

	int64_t found = -1;
	for (size_t i = list.items.num; i > 0 && found < 0; i--) {
		obs_sceneitem_t *item = list.items.array[i - 1];
		if (!obs_sceneitem_visible(item) || obs_sceneitem_locked(item))
			continue;

		struct matrix4 transform, inverse;
		obs_sceneitem_get_box_transform(item, &transform);
		if (!matrix4_inv(&inverse, &transform))
			continue;

		struct vec3 point;
		vec3_set(&point, x, y, 0.0f);
		vec3_transform(&point, &point, &inverse);
		if (point.x >= 0.0f && point.x <= 1.0f && point.y >= 0.0f && point.y <= 1.0f)
			found = obs_sceneitem_get_id(item);
	}

	free_items(&list);
	return found;
}

// 캔버스에 화면비를 유지해 꽉 차게 맞춘다
static void fit_item_to_canvas(obs_sceneitem_t *item)
{
	uint32_t width, height;
	canvas_size(&width, &height);

	struct vec2 bounds = {(float)width, (float)height};
	struct vec2 pos = {width * 0.5f, height * 0.5f};
	struct vec2 scale = {1.0f, 1.0f};
	obs_sceneitem_set_rot(item, 0.0f);
	obs_sceneitem_set_scale(item, &scale);
	obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_SCALE_INNER);
	obs_sceneitem_set_bounds(item, &bounds);
	obs_sceneitem_set_bounds_alignment(item, OBS_ALIGN_CENTER);
	obs_sceneitem_set_alignment(item, OBS_ALIGN_CENTER);
	obs_sceneitem_set_pos(item, &pos);
}

void core_scene_item_fit(int64_t id)
{
	obs_sceneitem_t *item = find_item(id);
	if (item) {
		fit_item_to_canvas(item);
		obs_sceneitem_release(item);
	}
}

void core_scene_item_reset(int64_t id)
{
	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return;

	struct vec2 pos = {0.0f, 0.0f};
	struct vec2 scale = {1.0f, 1.0f};
	obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_NONE);
	obs_sceneitem_set_alignment(item, OBS_ALIGN_TOP | OBS_ALIGN_LEFT);
	obs_sceneitem_set_rot(item, 0.0f);
	obs_sceneitem_set_scale(item, &scale);
	obs_sceneitem_set_pos(item, &pos);
	obs_sceneitem_release(item);
}

void core_scene_item_translate(int64_t id, float dx, float dy)
{
	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return;

	struct vec2 pos;
	obs_sceneitem_get_pos(item, &pos);
	pos.x += dx;
	pos.y += dy;
	obs_sceneitem_set_pos(item, &pos);
	obs_sceneitem_release(item);
}

// 캔버스의 한 점(cx, cy)을 기준으로 키우거나 줄인다. 바운드가 있으면 바운드를, 없으면 배율을 바꾼다.
void core_scene_item_scale(int64_t id, float factor, float cx, float cy)
{
	obs_sceneitem_t *item = find_item(id);
	if (!item || !isfinite(factor) || factor <= 0.0f) {
		obs_sceneitem_release(item);
		return;
	}

	struct vec2 pos;
	obs_sceneitem_get_pos(item, &pos);
	pos.x = cx + (pos.x - cx) * factor;
	pos.y = cy + (pos.y - cy) * factor;

	if (obs_sceneitem_get_bounds_type(item) != OBS_BOUNDS_NONE) {
		struct vec2 bounds;
		obs_sceneitem_get_bounds(item, &bounds);
		if (bounds.x * factor < 4.0f || bounds.y * factor < 4.0f) {
			obs_sceneitem_release(item);
			return;
		}
		bounds.x *= factor;
		bounds.y *= factor;
		obs_sceneitem_set_bounds(item, &bounds);
	} else {
		struct vec2 scale;
		obs_sceneitem_get_scale(item, &scale);
		if (fabsf(scale.x * factor) < 0.01f || fabsf(scale.y * factor) < 0.01f) {
			obs_sceneitem_release(item);
			return;
		}
		scale.x *= factor;
		scale.y *= factor;
		obs_sceneitem_set_scale(item, &scale);
	}

	obs_sceneitem_set_pos(item, &pos);
	obs_sceneitem_release(item);
}

void core_scene_item_set_visible(int64_t id, bool visible)
{
	obs_sceneitem_t *item = find_item(id);
	if (item) {
		obs_sceneitem_set_visible(item, visible);
		obs_sceneitem_release(item);
	}
}

void core_scene_item_set_locked(int64_t id, bool locked)
{
	obs_sceneitem_t *item = find_item(id);
	if (item) {
		obs_sceneitem_set_locked(item, locked);
		obs_sceneitem_release(item);
	}
}

void core_scene_item_order(int64_t id, int movement)
{
	obs_sceneitem_t *item = find_item(id);
	if (item) {
		obs_sceneitem_set_order(item, (enum obs_order_movement)movement);
		obs_sceneitem_release(item);
	}
}

void core_scene_item_remove(int64_t id)
{
	obs_sceneitem_t *item = find_item(id);
	if (item) {
		obs_sceneitem_remove(item);
		obs_sceneitem_release(item);
	}
}

#pragma mark - 소스 추가

// 앱에서 추가할 수 있는 소스 종류. 숨김·폐기·오디오 전용(전역 오디오 입력으로 따로 다룸) 종류는 뺀다.
char *core_source_types_json(void)
{
	obs_data_t *root = obs_data_create();
	obs_data_array_t *types = obs_data_array_create();

	const char *id;
	for (size_t i = 0; obs_enum_input_types(i, &id); i++) {
		const uint32_t flags = obs_get_source_output_flags(id);
		if (flags & (OBS_SOURCE_CAP_DISABLED | OBS_SOURCE_DEPRECATED))
			continue;
		if (!(flags & OBS_SOURCE_VIDEO))
			continue;
		// BGRA IOSurface 경로("Capture Card Device")는 iOS에서 확인하지 않았다
		if (strcmp(id, "macos-avcapture-fast") == 0)
			continue;

		obs_data_t *entry = obs_data_create();
		obs_data_set_string(entry, "id", id);
		obs_data_set_string(entry, "name", obs_source_get_display_name(id));
		obs_data_array_push_back(types, entry);
		obs_data_release(entry);
	}

	obs_data_set_array(root, "types", types);
	obs_data_array_release(types);
	return json_from(root);
}

static bool collect_camera_device(void *param, obs_source_t *source)
{
	DARRAY(char *) *ids = param;

	if (strcmp(obs_source_get_id(source), CAMERA_SOURCE_ID) == 0) {
		obs_data_t *settings = obs_source_get_settings(source);
		char *device = bstrdup(obs_data_get_string(settings, "device"));
		da_push_back(*ids, &device);
		obs_data_release(settings);
	}
	return true;
}

// 다른 카메라 소스가 쓰지 않는 카메라를 고른다 (같은 장치를 두 소스가 쓰는 일은 사용자가 고를 때만)
static char *unused_camera_id(void)
{
	DARRAY(char *) ids;
	da_init(ids);
	obs_enum_sources(collect_camera_device, &ids);

	char *camera_id = capture_unused_camera_id((const char *const *)ids.array, ids.num);

	for (size_t i = 0; i < ids.num; i++)
		bfree(ids.array[i]);
	da_free(ids);
	return camera_id;
}

// 현재 씬에 새 소스를 넣는다. 영상 소스는 캔버스에 맞춘다. 돌려주는 값은 항목 id (실패하면 -1).
int64_t core_scene_add_source(const char *type_id, const char *name)
{
	uint32_t width, height;
	canvas_size(&width, &height);

	obs_data_t *settings = obs_data_create();
	if (strcmp(type_id, "color_source_v3") == 0) {
		obs_data_set_int(settings, "width", width);
		obs_data_set_int(settings, "height", height);
	} else if (strcmp(type_id, CAMERA_SOURCE_ID) == 0) {
		char *camera_id = unused_camera_id();
		struct obs_video_info ovi;
		const uint32_t fps = obs_get_video_info(&ovi) && ovi.fps_den ? ovi.fps_num / ovi.fps_den : 60;
		capture_configure_camera(settings, camera_id, width, height, fps);
		bfree(camera_id);
	}

	const char *display_name = obs_source_get_display_name(type_id);
	char *unique = unique_source_name(name && *name ? name : display_name ? display_name : type_id);
	obs_source_t *source = obs_source_create(type_id, unique, settings, NULL);
	obs_data_release(settings);
	bfree(unique);

	if (!source)
		return -1;

	pthread_mutex_lock(&sc.mutex);
	obs_scene_t *scene = current_scene();
	obs_sceneitem_t *item = scene ? obs_scene_add(scene, source) : NULL;
	pthread_mutex_unlock(&sc.mutex);
	obs_source_release(source);

	if (!item)
		return -1;

	// 텍스트는 글자 크기 그대로 둔다 (캔버스에 맞추면 짧은 글이 크게 늘어난다)
	if (strcmp(type_id, "ios_text_source") != 0)
		fit_item_to_canvas(item);
	blog(LOG_INFO, "[app] added source '%s' (%s)", obs_source_get_name(source), type_id);
	return obs_sceneitem_get_id(item);
}

#pragma mark - 소스 속성

static const char *property_type_name(enum obs_property_type type)
{
	switch (type) {
	case OBS_PROPERTY_BOOL:
		return "bool";
	case OBS_PROPERTY_INT:
		return "int";
	case OBS_PROPERTY_FLOAT:
		return "float";
	case OBS_PROPERTY_TEXT:
		return "text";
	case OBS_PROPERTY_PATH:
		return "path";
	case OBS_PROPERTY_LIST:
		return "list";
	case OBS_PROPERTY_COLOR:
		return "color";
	case OBS_PROPERTY_COLOR_ALPHA:
		return "color_alpha";
	case OBS_PROPERTY_BUTTON:
		return "button";
	case OBS_PROPERTY_FONT:
		return "font";
	case OBS_PROPERTY_EDITABLE_LIST:
		return "editable_list";
	case OBS_PROPERTY_FRAME_RATE:
		return "frame_rate";
	case OBS_PROPERTY_GROUP:
		return "group";
	default:
		return "unknown";
	}
}

static void add_list_items(obs_data_t *entry, obs_property_t *property)
{
	const enum obs_combo_format format = obs_property_list_format(property);
	const char *format_name = format == OBS_COMBO_FORMAT_INT     ? "int"
				  : format == OBS_COMBO_FORMAT_FLOAT ? "float"
				  : format == OBS_COMBO_FORMAT_BOOL  ? "bool"
								     : "string";
	obs_data_set_string(entry, "format", format_name);

	obs_data_array_t *items = obs_data_array_create();
	const size_t count = obs_property_list_item_count(property);
	for (size_t i = 0; i < count; i++) {
		obs_data_t *item = obs_data_create();
		obs_data_set_string(item, "name", obs_property_list_item_name(property, i));
		obs_data_set_bool(item, "disabled", obs_property_list_item_disabled(property, i));

		switch (format) {
		case OBS_COMBO_FORMAT_INT:
			obs_data_set_int(item, "value", obs_property_list_item_int(property, i));
			break;
		case OBS_COMBO_FORMAT_FLOAT:
			obs_data_set_double(item, "value", obs_property_list_item_float(property, i));
			break;
		case OBS_COMBO_FORMAT_BOOL:
			obs_data_set_bool(item, "value", obs_property_list_item_bool(property, i));
			break;
		default:
			obs_data_set_string(item, "value", obs_property_list_item_string(property, i));
			break;
		}

		obs_data_array_push_back(items, item);
		obs_data_release(item);
	}
	obs_data_set_array(entry, "items", items);
	obs_data_array_release(items);
}

// 프레임 레이트 속성이 허용하는 fps 범위 (예: 카메라의 지금 입력 형식이 지원하는 범위)
static void add_frame_rate_ranges(obs_data_t *entry, obs_property_t *property)
{
	obs_data_array_t *ranges = obs_data_array_create();
	const size_t count = obs_property_frame_rate_fps_ranges_count(property);
	for (size_t i = 0; i < count; i++) {
		struct media_frames_per_second min = obs_property_frame_rate_fps_range_min(property, i);
		struct media_frames_per_second max = obs_property_frame_rate_fps_range_max(property, i);
		if (!min.denominator || !max.denominator)
			continue;

		obs_data_t *range = obs_data_create();
		obs_data_set_double(range, "min", media_frames_per_second_to_fps(min));
		obs_data_set_double(range, "max", media_frames_per_second_to_fps(max));
		obs_data_array_push_back(ranges, range);
		obs_data_release(range);
	}
	obs_data_set_array(entry, "fps_ranges", ranges);
	obs_data_array_release(ranges);
}

static void add_properties(obs_data_array_t *array, obs_properties_t *props, const char *group)
{
	for (obs_property_t *property = obs_properties_first(props); property; obs_property_next(&property)) {
		const enum obs_property_type type = obs_property_get_type(property);

		// 그룹은 펼쳐서 넣고 항목마다 그룹 이름을 단다
		if (type == OBS_PROPERTY_GROUP) {
			add_properties(array, obs_property_group_content(property), obs_property_description(property));
			continue;
		}

		obs_data_t *entry = obs_data_create();
		obs_data_set_string(entry, "name", obs_property_name(property));
		obs_data_set_string(entry, "type", property_type_name(type));
		obs_data_set_string(entry, "label", obs_property_description(property));
		obs_data_set_string(entry, "help", obs_property_long_description(property));
		obs_data_set_string(entry, "group", group ? group : "");
		obs_data_set_bool(entry, "enabled", obs_property_enabled(property));
		obs_data_set_bool(entry, "visible", obs_property_visible(property));

		switch (type) {
		case OBS_PROPERTY_INT:
			obs_data_set_int(entry, "min", obs_property_int_min(property));
			obs_data_set_int(entry, "max", obs_property_int_max(property));
			obs_data_set_int(entry, "step", obs_property_int_step(property));
			obs_data_set_string(entry, "suffix", obs_property_int_suffix(property));
			break;
		case OBS_PROPERTY_FLOAT:
			obs_data_set_double(entry, "min", obs_property_float_min(property));
			obs_data_set_double(entry, "max", obs_property_float_max(property));
			obs_data_set_double(entry, "step", obs_property_float_step(property));
			obs_data_set_string(entry, "suffix", obs_property_float_suffix(property));
			break;
		case OBS_PROPERTY_TEXT:
			obs_data_set_int(entry, "text_type", obs_property_text_type(property));
			break;
		case OBS_PROPERTY_PATH:
			obs_data_set_int(entry, "path_type", obs_property_path_type(property));
			obs_data_set_string(entry, "filter", obs_property_path_filter(property));
			break;
		case OBS_PROPERTY_LIST:
			add_list_items(entry, property);
			break;
		case OBS_PROPERTY_FRAME_RATE:
			add_frame_rate_ranges(entry, property);
			break;
		case OBS_PROPERTY_EDITABLE_LIST:
			// 0 문자열, 1 파일, 2 파일과 URL (enum obs_editable_list_type)
			obs_data_set_int(entry, "list_type", obs_property_editable_list_type(property));
			obs_data_set_string(entry, "filter", obs_property_editable_list_filter(property));
			break;
		default:
			break;
		}

		obs_data_array_push_back(array, entry);
		obs_data_release(entry);
	}
}

char *core_source_properties_json(const char *source_name)
{
	obs_source_t *source = find_source(source_name);
	if (!source)
		return NULL;

	obs_properties_t *props = obs_source_properties(source);
	obs_data_t *settings = obs_source_get_settings(source);

	obs_data_t *root = obs_data_create();
	obs_data_set_string(root, "type", obs_source_get_id(source));

	obs_data_array_t *array = obs_data_array_create();
	if (props)
		add_properties(array, props, NULL);
	obs_data_set_array(root, "properties", array);
	obs_data_array_release(array);

	// 기본값까지 포함한 현재 설정
	obs_data_t *values = obs_data_create_from_json(obs_data_get_json_with_defaults(settings));
	obs_data_set_obj(root, "settings", values);
	obs_data_release(values);

	obs_data_release(settings);
	obs_properties_destroy(props);
	obs_source_release(source);
	return json_from(root);
}

// 소스의 지금 크기 (CI 시험용)
bool core_source_size(const char *source_name, uint32_t *width, uint32_t *height)
{
	obs_source_t *source = find_source(source_name);
	*width = source ? obs_source_get_width(source) : 0;
	*height = source ? obs_source_get_height(source) : 0;
	obs_source_release(source);
	return source != NULL;
}

// 바뀐 설정만 담은 JSON을 소스 설정에 덮어쓴다. 카메라 장치가 바뀌면 캔버스에 맞는 형식도 다시 고른다.
void core_source_update(const char *source_name, const char *changes_json)
{
	obs_source_t *source = find_source(source_name);
	if (!source)
		return;

	obs_data_t *changes = obs_data_create_from_json(changes_json);
	obs_data_t *settings = obs_source_get_settings(source);
	obs_data_apply(settings, changes);

	if (strcmp(obs_source_get_id(source), CAMERA_SOURCE_ID) == 0) {
		uint32_t width, height;
		canvas_size(&width, &height);
		struct obs_video_info ovi;
		const bool have_video = obs_get_video_info(&ovi) && ovi.fps_den;
		const uint32_t fps = have_video ? ovi.fps_num / ovi.fps_den : 60;

		if (obs_data_has_user_value(changes, "device")) {
			capture_configure_camera(settings, obs_data_get_string(changes, "device"), width, height, fps);
		} else if (obs_data_has_user_value(changes, "supported_format") &&
			   !obs_data_has_user_value(changes, "frame_rate")) {
			// 입력 형식을 바꾸면 fps를 그 형식이 지원하는 값 중 캔버스에 가까운 것으로
			capture_fit_frame_rate(settings, have_video ? ovi.fps_num : 60, have_video ? ovi.fps_den : 1);
		} else if (obs_data_has_user_value(changes, "use_preset") && !obs_data_get_bool(changes, "use_preset") &&
			   !*obs_data_get_string(settings, "supported_format")) {
			// 프리셋을 끄면 고른 형식이 없으니 캔버스에 맞는 형식을 고른다
			char *device = bstrdup(obs_data_get_string(settings, "device"));
			capture_configure_camera(settings, device, width, height, fps);
			bfree(device);
		}
	}

	obs_source_update(source, settings);

	obs_data_release(settings);
	obs_data_release(changes);
	obs_source_release(source);
}

void core_source_press_button(const char *source_name, const char *property_name)
{
	obs_source_t *source = find_source(source_name);
	if (!source)
		return;

	obs_properties_t *props = obs_source_properties(source);
	obs_property_t *property = props ? obs_properties_get(props, property_name) : NULL;
	if (property)
		obs_property_button_clicked(property, source);

	obs_properties_destroy(props);
	obs_source_release(source);
}

bool core_source_rename(const char *source_name, const char *new_name)
{
	if (!new_name || !*new_name)
		return false;

	obs_source_t *existing = obs_get_source_by_name(new_name);
	if (existing) {
		obs_source_release(existing);
		return false;
	}

	obs_source_t *source = obs_get_source_by_name(source_name);
	if (!source)
		return false;
	obs_source_set_name(source, new_name);
	obs_source_release(source);
	return true;
}

#pragma mark - 오디오

void core_source_set_volume(const char *source_name, float multiplier)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	if (source) {
		obs_source_set_volume(source, multiplier);
		obs_source_release(source);
	}
}

void core_source_set_muted(const char *source_name, bool muted)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	if (source) {
		obs_source_set_muted(source, muted);
		obs_source_release(source);
	}
}

float core_source_volume(const char *source_name)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	float volume = source ? obs_source_get_volume(source) : 0.0f;
	obs_source_release(source);
	return volume;
}

bool core_source_muted(const char *source_name)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	bool muted = source ? obs_source_muted(source) : false;
	obs_source_release(source);
	return muted;
}

#pragma mark - 미디어 조작

// action: 0 재생/일시정지 전환, 1 처음부터, 2 정지. 돌려주는 값은 조작 뒤 상태 (enum obs_media_state)
int core_source_media(const char *source_name, int action)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	if (!source)
		return OBS_MEDIA_STATE_NONE;

	switch (action) {
	case 0: {
		const enum obs_media_state state = obs_source_media_get_state(source);
		if (state == OBS_MEDIA_STATE_PLAYING)
			obs_source_media_play_pause(source, true);
		else if (state == OBS_MEDIA_STATE_PAUSED)
			obs_source_media_play_pause(source, false);
		else
			obs_source_media_restart(source);
		break;
	}
	case 1:
		obs_source_media_restart(source);
		break;
	case 2:
		obs_source_media_stop(source);
		break;
	default:
		break;
	}

	const enum obs_media_state state = obs_source_media_get_state(source);
	obs_source_release(source);
	return state;
}

#pragma mark - 필터

// 소스에 넣을 수 있는 오디오 필터 종류 (소스에 소리가 없으면 비어 있다)
char *core_filter_types_json(const char *source_name)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	const bool has_audio = source && (obs_source_get_output_flags(source) & OBS_SOURCE_AUDIO) != 0;
	obs_source_release(source);

	obs_data_array_t *types = obs_data_array_create();
	const char *id;
	for (size_t i = 0; has_audio && obs_enum_filter_types(i, &id); i++) {
		const uint32_t flags = obs_get_source_output_flags(id);
		if (!(flags & OBS_SOURCE_AUDIO) || (flags & OBS_SOURCE_VIDEO) ||
		    (flags & (OBS_SOURCE_DEPRECATED | OBS_SOURCE_CAP_DISABLED)))
			continue;

		obs_data_t *type = obs_data_create();
		obs_data_set_string(type, "id", id);
		obs_data_set_string(type, "name", obs_source_get_display_name(id));
		obs_data_array_push_back(types, type);
		obs_data_release(type);
	}

	obs_data_t *root = obs_data_create();
	obs_data_set_array(root, "types", types);
	obs_data_array_release(types);
	return json_from(root);
}

static void add_filter_entry(obs_source_t *parent, obs_source_t *filter, void *param)
{
	UNUSED_PARAMETER(parent);
	obs_data_t *entry = obs_data_create();
	obs_data_set_string(entry, "name", obs_source_get_name(filter));
	obs_data_set_string(entry, "id", obs_source_get_id(filter));
	obs_data_set_string(entry, "type_name", obs_source_get_display_name(obs_source_get_id(filter)));
	obs_data_set_bool(entry, "enabled", obs_source_enabled(filter));
	obs_data_array_push_back(param, entry);
	obs_data_release(entry);
}

// 소스의 필터 목록, 적용 순서대로: {"filters": [{"name", "id", "type_name", "enabled"}]}
char *core_filters_json(const char *source_name)
{
	obs_data_array_t *filters = obs_data_array_create();
	obs_source_t *source = obs_get_source_by_name(source_name);
	if (source)
		obs_source_enum_filters(source, add_filter_entry, filters);
	obs_source_release(source);

	obs_data_t *root = obs_data_create();
	obs_data_set_array(root, "filters", filters);
	obs_data_array_release(filters);
	return json_from(root);
}

// 필터를 맨 뒤에 넣는다. 이름은 종류 이름에서 겹치지 않게 만든다.
bool core_filter_add(const char *source_name, const char *type_id)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	if (!source)
		return false;

	const char *base = obs_source_get_display_name(type_id);
	struct dstr name = {0};
	dstr_copy(&name, base ? base : type_id);
	for (int i = 2;; i++) {
		obs_source_t *existing = obs_source_get_filter_by_name(source, name.array);
		if (!existing)
			break;
		obs_source_release(existing);
		dstr_printf(&name, "%s %d", base ? base : type_id, i);
	}

	obs_source_t *filter = obs_source_create(type_id, name.array, NULL, NULL);
	if (filter) {
		obs_source_filter_add(source, filter);
		blog(LOG_INFO, "[app] filter '%s' (%s) added to '%s'", name.array, type_id, source_name);
	}

	obs_source_release(filter);
	dstr_free(&name);
	obs_source_release(source);
	return filter != NULL;
}

void core_filter_remove(const char *source_name, const char *filter_name)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	obs_source_t *filter = source ? obs_source_get_filter_by_name(source, filter_name) : NULL;
	if (filter)
		obs_source_filter_remove(source, filter);
	obs_source_release(filter);
	obs_source_release(source);
}

void core_filter_set_enabled(const char *source_name, const char *filter_name, bool enabled)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	obs_source_t *filter = source ? obs_source_get_filter_by_name(source, filter_name) : NULL;
	if (filter)
		obs_source_set_enabled(filter, enabled);
	obs_source_release(filter);
	obs_source_release(source);
}

// direction: -1이면 목록에서 위로(먼저 적용), +1이면 아래로
void core_filter_move(const char *source_name, const char *filter_name, int direction)
{
	obs_source_t *source = obs_get_source_by_name(source_name);
	obs_source_t *filter = source ? obs_source_get_filter_by_name(source, filter_name) : NULL;
	if (filter)
		obs_source_filter_set_order(source, filter, direction < 0 ? OBS_ORDER_MOVE_UP : OBS_ORDER_MOVE_DOWN);
	obs_source_release(filter);
	obs_source_release(source);
}

#pragma mark - 첫 카메라

obs_source_t *scenes_primary_camera(void)
{
	struct item_list list;
	collect_items(&list);

	obs_source_t *camera = NULL;
	for (size_t i = list.items.num; i > 0 && !camera; i--) {
		obs_source_t *source = obs_sceneitem_get_source(list.items.array[i - 1]);
		if (strcmp(obs_source_get_id(source), CAMERA_SOURCE_ID) == 0)
			camera = obs_source_get_ref(source);
	}

	free_items(&list);
	return camera;
}

#pragma mark - 저장·불러오기

struct load_context {
	DARRAY(obs_source_t *) scenes;
	obs_source_t *audio_input;
};

static void loaded_source(void *param, obs_source_t *source)
{
	struct load_context *context = param;

	// obs_load_sources는 끝에 참조를 놓으므로, 계속 쓸 소스는 여기서 붙잡는다
	if (obs_scene_from_source(source)) {
		obs_source_t *ref = obs_source_get_ref(source);
		da_push_back(context->scenes, &ref);
	} else if (strcmp(obs_source_get_id(source), AUDIO_INPUT_SOURCE_ID) == 0 && !context->audio_input) {
		context->audio_input = obs_source_get_ref(source);
	}
}

obs_source_t *scenes_load(const char *path)
{
	obs_data_t *root = obs_data_create_from_json_file_safe(path, "bak");
	if (!root)
		return NULL;

	struct load_context context = {0};
	obs_data_array_t *sources = obs_data_get_array(root, "sources");
	obs_load_sources(sources, loaded_source, &context);
	obs_data_array_release(sources);

	pthread_mutex_lock(&sc.mutex);

	// 저장한 순서대로 놓고, 순서에 없는 씬은 뒤에 붙인다
	obs_data_array_t *order = obs_data_get_array(root, "scene_order");
	const size_t order_count = order ? obs_data_array_count(order) : 0;
	for (size_t i = 0; i < order_count; i++) {
		obs_data_t *entry = obs_data_array_item(order, i);
		const char *name = obs_data_get_string(entry, "name");
		for (size_t j = 0; j < context.scenes.num; j++) {
			if (context.scenes.array[j] && strcmp(obs_source_get_name(context.scenes.array[j]), name) == 0) {
				da_push_back(sc.scenes, &context.scenes.array[j]);
				context.scenes.array[j] = NULL;
				break;
			}
		}
		obs_data_release(entry);
	}
	obs_data_array_release(order);

	for (size_t j = 0; j < context.scenes.num; j++) {
		if (context.scenes.array[j])
			da_push_back(sc.scenes, &context.scenes.array[j]);
	}
	da_free(context.scenes);

	obs_source_t *current = find_scene_locked(obs_data_get_string(root, "current_scene"));
	if (!current && sc.scenes.num)
		current = sc.scenes.array[0];
	if (current)
		set_current_locked(current);

	blog(LOG_INFO, "[app] loaded %zu scene(s) from %s", sc.scenes.num, path);
	pthread_mutex_unlock(&sc.mutex);

	obs_data_release(root);
	return context.audio_input;
}

bool scenes_empty(void)
{
	pthread_mutex_lock(&sc.mutex);
	bool empty = sc.scenes.num == 0;
	pthread_mutex_unlock(&sc.mutex);
	return empty;
}

// 처음 실행: 배경색과 카메라가 든 씬 하나
void scenes_create_default(void)
{
	pthread_mutex_lock(&sc.mutex);
	obs_scene_t *scene = add_scene_locked("장면 1");
	if (scene)
		set_current_locked(obs_scene_get_source(scene));
	pthread_mutex_unlock(&sc.mutex);

	if (!scene)
		return;

	int64_t background = core_scene_add_source("color_source_v3", "배경");
	if (background >= 0) {
		obs_source_t *source = obs_get_source_by_name("배경");
		obs_data_t *settings = obs_data_create();
		obs_data_set_int(settings, "color", 0xFF3A2414);
		obs_source_update(source, settings);
		obs_data_release(settings);
		obs_source_release(source);
	}
	core_scene_add_source(CAMERA_SOURCE_ID, "카메라");
	blog(LOG_INFO, "[app] created the default scene");
}

bool core_collection_save(const char *path, const char *audio_input_name)
{
	obs_data_t *root = obs_data_create();
	obs_data_array_t *sources = obs_save_sources();
	obs_data_set_array(root, "sources", sources);
	obs_data_array_release(sources);

	obs_data_array_t *order = obs_data_array_create();
	pthread_mutex_lock(&sc.mutex);
	for (size_t i = 0; i < sc.scenes.num; i++) {
		obs_data_t *entry = obs_data_create();
		obs_data_set_string(entry, "name", obs_source_get_name(sc.scenes.array[i]));
		obs_data_array_push_back(order, entry);
		obs_data_release(entry);
	}
	obs_data_set_string(root, "current_scene", sc.current ? obs_source_get_name(sc.current) : "");
	pthread_mutex_unlock(&sc.mutex);

	obs_data_set_array(root, "scene_order", order);
	obs_data_array_release(order);
	obs_data_set_string(root, "audio_input", audio_input_name ? audio_input_name : "");

	bool saved = obs_data_save_json_safe(root, path, "tmp", "bak");
	obs_data_release(root);
	if (!saved)
		blog(LOG_WARNING, "[app] failed to save the scene collection to %s", path);
	return saved;
}
