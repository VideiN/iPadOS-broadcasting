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
	const struct obs_sceneitem_crop no_crop = {0};
	obs_sceneitem_set_crop(item, &no_crop);
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

#pragma mark - 미리보기 편집 (P11): 핸들로 크기·자르기·회전, 스냅, 숫자 변형

// OBS frontend/widgets/OBSBasicPreview.cpp의 StretchItem·CropItem·RotateItem·GetSnapOffset 계산을 옮겼다.
// 끌기는 한 번에 하나라서 시작할 때의 값을 여기에 둔다 (메인 스레드에서만 부른다).
static struct {
	obs_sceneitem_t *item;
	int mode;
	uint32_t handle;
	struct vec2 start_point;     // 끌기를 시작한 캔버스 좌표
	struct vec2 start_pos;       // 그때 항목의 pos
	struct vec2 start_size;      // 그때 보이는 크기 (GetItemSize)
	struct obs_sceneitem_crop start_crop;
	struct matrix4 item_to_screen; // 회전만 있는 항목 좌표 → 캔버스
	struct matrix4 screen_to_item;
	struct vec2 rotate_center;   // 회전: 상자 가운데
	struct vec2 rotate_offset;   // 회전: 가운데에서 pos까지 (회전을 푼 값)
	struct vec2 last_point;      // 옮기기: 지난번 손가락 위치
	struct vec2 snapped;         // 옮기기: 지금 pos에 더해 둔 스냅 이동량
} drag;

static float rad(float degrees)
{
	return degrees * (float)M_PI / 180.0f;
}

static void rotate_vec2(struct vec2 *v, float radians)
{
	const float c = cosf(radians), s = sinf(radians);
	const float x = c * v->x - s * v->y;
	const float y = s * v->x + c * v->y;
	vec2_set(v, x, y);
}

// 보이는 크기: 바운드가 있으면 바운드, 없으면 (원본 - 자르기) × 배율
static struct vec2 item_size(obs_sceneitem_t *item)
{
	struct vec2 size;
	if (obs_sceneitem_get_bounds_type(item) != OBS_BOUNDS_NONE) {
		obs_sceneitem_get_bounds(item, &size);
		return size;
	}
	obs_source_t *source = obs_sceneitem_get_source(item);
	struct obs_sceneitem_crop crop;
	struct vec2 scale;
	obs_sceneitem_get_scale(item, &scale);
	obs_sceneitem_get_crop(item, &crop);
	size.x = fmaxf((float)((int)obs_source_get_width(source) - crop.left - crop.right), 0.0f);
	size.y = fmaxf((float)((int)obs_source_get_height(source) - crop.top - crop.bottom), 0.0f);
	vec2_mul(&size, &size, &scale);
	return size;
}

static struct vec2 box_center(obs_sceneitem_t *item)
{
	struct vec3 box[4];
	item_box(item, box);
	struct vec2 center = {(box[0].x + box[2].x) * 0.5f, (box[0].y + box[2].y) * 0.5f};
	return center;
}

static void box_bounds(obs_sceneitem_t *item, struct vec3 *tl, struct vec3 *br)
{
	struct vec3 box[4];
	item_box(item, box);
	vec3_copy(tl, &box[0]);
	vec3_copy(br, &box[0]);
	for (int i = 1; i < 4; i++) {
		vec3_min(tl, tl, &box[i]);
		vec3_max(br, br, &box[i]);
	}
}

// 캔버스 가장자리·가운데선에 snap 거리 안이면 붙일 만큼의 이동량. 안내선 위치를 feedback에 남긴다
static struct vec3 snap_offset(const struct vec3 *tl, const struct vec3 *br, float distance,
			       struct core_drag_feedback *feedback)
{
	struct vec3 offset;
	vec3_zero(&offset);
	if (distance <= 0.0f)
		return offset;

	uint32_t width, height;
	canvas_size(&width, &height);
	const float w = (float)width, h = (float)height;
	const float center_x = br->x - (br->x - tl->x) / 2.0f;
	const float center_y = br->y - (br->y - tl->y) / 2.0f;

	if (fabsf(tl->x) < distance) {
		offset.x = -tl->x;
		feedback->snap_x = true;
		feedback->guide_x = 0.0f;
	} else if (fabsf(w - br->x) < distance) {
		offset.x = w - br->x;
		feedback->snap_x = true;
		feedback->guide_x = w;
	} else if (fabsf(w - (br->x - tl->x)) > distance && fabsf(w / 2.0f - center_x) < distance) {
		offset.x = w / 2.0f - center_x;
		feedback->snap_x = true;
		feedback->guide_x = w / 2.0f;
	}

	if (fabsf(tl->y) < distance) {
		offset.y = -tl->y;
		feedback->snap_y = true;
		feedback->guide_y = 0.0f;
	} else if (fabsf(h - br->y) < distance) {
		offset.y = h - br->y;
		feedback->snap_y = true;
		feedback->guide_y = h;
	} else if (fabsf(h - (br->y - tl->y)) > distance && fabsf(h / 2.0f - center_y) < distance) {
		offset.y = h / 2.0f - center_y;
		feedback->snap_y = true;
		feedback->guide_y = h / 2.0f;
	}
	return offset;
}

bool core_scene_item_drag_begin(int64_t id, int mode, int handle, float x, float y)
{
	core_scene_item_drag_end();

	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return false;
	if (obs_sceneitem_locked(item)) {
		obs_sceneitem_release(item);
		return false;
	}

	drag.item = item;
	drag.mode = mode;
	drag.handle = (uint32_t)handle;
	vec2_set(&drag.start_point, x, y);
	drag.last_point = drag.start_point;
	vec2_zero(&drag.snapped);
	obs_sceneitem_get_pos(item, &drag.start_pos);
	obs_sceneitem_get_crop(item, &drag.start_crop);
	drag.start_size = item_size(item);

	struct matrix4 box_transform;
	obs_sceneitem_get_box_transform(item, &box_transform);
	const float rot = obs_sceneitem_get_rot(item);
	struct vec3 upper_left;
	vec3_from_vec4(&upper_left, &box_transform.t);

	matrix4_identity(&drag.item_to_screen);
	matrix4_rotate_aa4f(&drag.item_to_screen, &drag.item_to_screen, 0.0f, 0.0f, 1.0f, rad(rot));
	matrix4_translate3f(&drag.item_to_screen, &drag.item_to_screen, upper_left.x, upper_left.y, 0.0f);

	matrix4_identity(&drag.screen_to_item);
	matrix4_translate3f(&drag.screen_to_item, &drag.screen_to_item, -upper_left.x, -upper_left.y, 0.0f);
	matrix4_rotate_aa4f(&drag.screen_to_item, &drag.screen_to_item, 0.0f, 0.0f, 1.0f, rad(-rot));

	drag.rotate_center = box_center(item);
	drag.rotate_offset = drag.start_pos;
	vec2_sub(&drag.rotate_offset, &drag.rotate_offset, &drag.rotate_center);
	rotate_vec2(&drag.rotate_offset, -rad(rot));
	return true;
}

// 손가락이 움직인 만큼 옮긴다. 두 손가락으로 크기·회전을 같이 바꾸면 pos가 따로 바뀌므로
// 시작 위치가 아니라 지금 pos에서 (지난번 스냅을 빼고) 더한다
static void drag_move(float x, float y, float snap, struct core_drag_feedback *feedback)
{
	struct vec2 pos;
	obs_sceneitem_get_pos(drag.item, &pos);
	pos.x += x - drag.last_point.x - drag.snapped.x;
	pos.y += y - drag.last_point.y - drag.snapped.y;
	vec2_set(&drag.last_point, x, y);
	vec2_zero(&drag.snapped);
	obs_sceneitem_set_pos(drag.item, &pos);

	struct vec3 tl, br;
	box_bounds(drag.item, &tl, &br);
	const struct vec3 offset = snap_offset(&tl, &br, snap, feedback);
	if (offset.x != 0.0f || offset.y != 0.0f) {
		pos.x += offset.x;
		pos.y += offset.y;
		vec2_set(&drag.snapped, offset.x, offset.y);
		obs_sceneitem_set_pos(drag.item, &pos);
	}
}

// 모서리를 끌면 시작할 때의 비율을 지킨다 (변은 그 방향으로만)
static void clamp_aspect(struct vec3 *tl, struct vec3 *br, struct vec2 *size)
{
	const uint32_t h = drag.handle;
	const bool corner = (h & (CORE_HANDLE_LEFT | CORE_HANDLE_RIGHT)) && (h & (CORE_HANDLE_TOP | CORE_HANDLE_BOTTOM));
	if (!corner || drag.start_size.x <= 0.0f || drag.start_size.y <= 0.0f)
		return;

	const float base_aspect = drag.start_size.x / drag.start_size.y;
	const float aspect = size->y != 0.0f ? size->x / size->y : base_aspect;
	const bool same_sign = (size->y >= 0.0f && size->x >= 0.0f) || (size->y <= 0.0f && size->x <= 0.0f);
	if (aspect < base_aspect)
		size->x = size->y * base_aspect * (same_sign ? 1.0f : -1.0f);
	else
		size->y = size->x / base_aspect * (same_sign ? 1.0f : -1.0f);

	size->x = roundf(size->x);
	size->y = roundf(size->y);
	if (h & CORE_HANDLE_LEFT)
		tl->x = br->x - size->x;
	else if (h & CORE_HANDLE_RIGHT)
		br->x = tl->x + size->x;
	if (h & CORE_HANDLE_TOP)
		tl->y = br->y - size->y;
	else if (h & CORE_HANDLE_BOTTOM)
		br->y = tl->y + size->y;
}

static struct vec3 transformed(float x, float y, const struct matrix4 *m)
{
	struct vec3 v;
	vec3_set(&v, x, y, 0.0f);
	vec3_transform(&v, &v, m);
	return v;
}

static void snap_stretch(struct vec3 *tl, struct vec3 *br, float snap, struct core_drag_feedback *feedback)
{
	struct vec3 corners[4] = {
		transformed(tl->x, tl->y, &drag.item_to_screen),
		transformed(br->x, tl->y, &drag.item_to_screen),
		transformed(tl->x, br->y, &drag.item_to_screen),
		transformed(br->x, br->y, &drag.item_to_screen),
	};
	struct vec3 bound_tl = corners[0], bound_br = corners[0];
	for (int i = 1; i < 4; i++) {
		vec3_min(&bound_tl, &bound_tl, &corners[i]);
		vec3_max(&bound_br, &bound_br, &corners[i]);
	}

	struct vec3 offset = snap_offset(&bound_tl, &bound_br, snap, feedback);
	vec3_add(&offset, &offset, &corners[0]);
	vec3_transform(&offset, &offset, &drag.screen_to_item);
	vec3_sub(&offset, &offset, tl);

	if (drag.handle & CORE_HANDLE_LEFT)
		tl->x += offset.x;
	else if (drag.handle & CORE_HANDLE_RIGHT)
		br->x += offset.x;
	if (drag.handle & CORE_HANDLE_TOP)
		tl->y += offset.y;
	else if (drag.handle & CORE_HANDLE_BOTTOM)
		br->y += offset.y;
}

// 정렬점(pos)이 새 상자에서 있을 자리 (항목 좌표)
static struct vec3 stretch_pos(const struct vec3 *tl, const struct vec3 *br)
{
	const uint32_t alignment = obs_sceneitem_get_alignment(drag.item);
	struct vec3 pos;
	vec3_zero(&pos);
	if (alignment & OBS_ALIGN_LEFT)
		pos.x = tl->x;
	else if (alignment & OBS_ALIGN_RIGHT)
		pos.x = br->x;
	else
		pos.x = (br->x - tl->x) * 0.5f + tl->x;
	if (alignment & OBS_ALIGN_TOP)
		pos.y = tl->y;
	else if (alignment & OBS_ALIGN_BOTTOM)
		pos.y = br->y;
	else
		pos.y = (br->y - tl->y) * 0.5f + tl->y;
	return pos;
}

static void drag_stretch(float x, float y, bool keep_aspect, float snap, struct core_drag_feedback *feedback)
{
	struct vec3 tl, br;
	vec3_zero(&tl);
	vec3_set(&br, drag.start_size.x, drag.start_size.y, 0.0f);
	const struct vec3 point = transformed(x, y, &drag.screen_to_item);

	if (drag.handle & CORE_HANDLE_LEFT)
		tl.x = point.x;
	else if (drag.handle & CORE_HANDLE_RIGHT)
		br.x = point.x;
	if (drag.handle & CORE_HANDLE_TOP)
		tl.y = point.y;
	else if (drag.handle & CORE_HANDLE_BOTTOM)
		br.y = point.y;

	snap_stretch(&tl, &br, snap, feedback);

	obs_source_t *source = obs_sceneitem_get_source(drag.item);
	const uint32_t source_cx = obs_source_get_width(source);
	const uint32_t source_cy = obs_source_get_height(source);
	if (!source_cx || !source_cy)
		return;

	struct vec2 size = {br.x - tl.x, br.y - tl.y};
	if (keep_aspect)
		clamp_aspect(&tl, &br, &size);

	if (obs_sceneitem_get_bounds_type(drag.item) != OBS_BOUNDS_NONE) {
		if (tl.x > br.x) {
			const float t = tl.x;
			tl.x = br.x;
			br.x = t;
		}
		if (tl.y > br.y) {
			const float t = tl.y;
			tl.y = br.y;
			br.y = t;
		}
		size.x = fmaxf(fabsf(size.x), 4.0f);
		size.y = fmaxf(fabsf(size.y), 4.0f);
		obs_sceneitem_set_bounds(drag.item, &size);
	} else {
		struct obs_sceneitem_crop crop;
		obs_sceneitem_get_crop(drag.item, &crop);
		struct vec2 base = {(float)source_cx - (float)(crop.left + crop.right),
				    (float)source_cy - (float)(crop.top + crop.bottom)};
		if (base.x < 1.0f || base.y < 1.0f)
			return;
		struct vec2 scale = {size.x / base.x, size.y / base.y};
		// 아주 작게 줄이면 다시 잡을 수 없으니 막는다 (뒤집기는 허용)
		if (fabsf(scale.x) < 0.01f || fabsf(scale.y) < 0.01f)
			return;
		obs_sceneitem_set_scale(drag.item, &scale);
	}

	struct vec3 pos = stretch_pos(&tl, &br);
	vec3_transform(&pos, &pos, &drag.item_to_screen);
	struct vec2 new_pos = {roundf(pos.x), roundf(pos.y)};
	obs_sceneitem_set_pos(drag.item, &new_pos);
}

static void drag_crop(float x, float y)
{
	const bool bounded = obs_sceneitem_get_bounds_type(drag.item) != OBS_BOUNDS_NONE;
	const uint32_t h = drag.handle;
	const uint32_t align = obs_sceneitem_get_alignment(drag.item);
	struct vec3 tl, br;
	vec3_zero(&tl);
	vec3_set(&br, drag.start_size.x, drag.start_size.y, 0.0f);
	struct vec3 point = transformed(x, y, &drag.screen_to_item);

	struct obs_sceneitem_crop crop = drag.start_crop;
	struct vec2 raw_scale, scale;
	obs_sceneitem_get_scale(drag.item, &raw_scale);
	vec2_set(&scale, bounded ? fabsf(raw_scale.x) : raw_scale.x, bounded ? fabsf(raw_scale.y) : raw_scale.y);
	if (scale.x == 0.0f || scale.y == 0.0f)
		return;

	const struct vec2 max_tl = {(float)-crop.left * scale.x, (float)-crop.top * scale.y};
	const struct vec2 max_br = {drag.start_size.x + crop.right * scale.x, drag.start_size.y + crop.bottom * scale.y};
	const bool flip_x = scale.x < 0.0f && !bounded, flip_y = scale.y < 0.0f && !bounded;
#define MIN_X(a, b) (flip_x ? fmaxf(a, b) : fminf(a, b))
#define MAX_X(a, b) (flip_x ? fminf(a, b) : fmaxf(a, b))
#define MIN_Y(a, b) (flip_y ? fmaxf(a, b) : fminf(a, b))
#define MAX_Y(a, b) (flip_y ? fminf(a, b) : fmaxf(a, b))
	point.x = MAX_X(MIN_X(point.x, max_br.x), max_tl.x);
	point.y = MAX_Y(MIN_Y(point.y, max_br.y), max_tl.y);

	// 남는 크기는 원본 2픽셀 이상
	if (h & CORE_HANDLE_LEFT)
		point.x = tl.x = MIN_X(point.x, drag.start_size.x - 2.0f * scale.x);
	else if (h & CORE_HANDLE_RIGHT)
		point.x = br.x = MAX_X(point.x, 2.0f * scale.x);
	if (h & CORE_HANDLE_TOP)
		point.y = tl.y = MIN_Y(point.y, drag.start_size.y - 2.0f * scale.y);
	else if (h & CORE_HANDLE_BOTTOM)
		point.y = br.y = MAX_Y(point.y, 2.0f * scale.y);
#undef MIN_X
#undef MAX_X
#undef MIN_Y
#undef MAX_Y

	const uint32_t align_x_mask = OBS_ALIGN_LEFT | OBS_ALIGN_RIGHT;
	const uint32_t align_y_mask = OBS_ALIGN_TOP | OBS_ALIGN_BOTTOM;
	const uint32_t handle_x = (h & CORE_HANDLE_LEFT ? OBS_ALIGN_LEFT : 0) | (h & CORE_HANDLE_RIGHT ? OBS_ALIGN_RIGHT : 0);
	const uint32_t handle_y = (h & CORE_HANDLE_TOP ? OBS_ALIGN_TOP : 0) | (h & CORE_HANDLE_BOTTOM ? OBS_ALIGN_BOTTOM : 0);
	struct vec3 new_pos;
	vec3_zero(&new_pos);
	if ((align & align_x_mask) == handle_x && handle_x != 0)
		new_pos.x = point.x;
	else if (align & OBS_ALIGN_RIGHT)
		new_pos.x = drag.start_size.x;
	else if (!(align & OBS_ALIGN_LEFT))
		new_pos.x = drag.start_size.x * 0.5f;
	if ((align & align_y_mask) == handle_y && handle_y != 0)
		new_pos.y = point.y;
	else if (align & OBS_ALIGN_BOTTOM)
		new_pos.y = drag.start_size.y;
	else if (!(align & OBS_ALIGN_TOP))
		new_pos.y = drag.start_size.y * 0.5f;

	if (h & CORE_HANDLE_LEFT)
		crop.left += (int)roundf(tl.x / scale.x);
	else if (h & CORE_HANDLE_RIGHT)
		crop.right += (int)roundf((drag.start_size.x - br.x) / scale.x);
	if (h & CORE_HANDLE_TOP)
		crop.top += (int)roundf(tl.y / scale.y);
	else if (h & CORE_HANDLE_BOTTOM)
		crop.bottom += (int)roundf((drag.start_size.y - br.y) / scale.y);
	crop.left = crop.left < 0 ? 0 : crop.left;
	crop.right = crop.right < 0 ? 0 : crop.right;
	crop.top = crop.top < 0 ? 0 : crop.top;
	crop.bottom = crop.bottom < 0 ? 0 : crop.bottom;

	vec3_transform(&new_pos, &new_pos, &drag.item_to_screen);
	struct vec2 pos = {roundf(new_pos.x), roundf(new_pos.y)};

	obs_sceneitem_defer_update_begin(drag.item);
	obs_sceneitem_set_crop(drag.item, &crop);
	if (!bounded)
		obs_sceneitem_set_pos(drag.item, &pos);
	obs_sceneitem_defer_update_end(drag.item);
}

// 0·90·180·270°에서 3° 안이면 붙인다
static float snapped_angle(float degrees)
{
	float angle = fmodf(degrees, 360.0f);
	if (angle < 0.0f)
		angle += 360.0f;
	for (int i = 0; i <= 4; i++) {
		if (fabsf(angle - i * 90.0f) < 3.0f)
			return fmodf(i * 90.0f, 360.0f);
	}
	return angle;
}

static void drag_rotate(float x, float y)
{
	const float degrees = atan2f(y - drag.rotate_center.y, x - drag.rotate_center.x) * 180.0f / (float)M_PI + 90.0f;
	const float angle = snapped_angle(degrees);

	struct vec2 pos = drag.rotate_offset;
	rotate_vec2(&pos, rad(angle));
	pos.x += drag.rotate_center.x;
	pos.y += drag.rotate_center.y;
	obs_sceneitem_set_rot(drag.item, angle);
	obs_sceneitem_set_pos(drag.item, &pos);
}

void core_scene_item_drag_to(float x, float y, bool keep_aspect, float snap_distance,
			     struct core_drag_feedback *feedback)
{
	struct core_drag_feedback local = {0};
	if (!feedback)
		feedback = &local;
	memset(feedback, 0, sizeof(*feedback));
	if (!drag.item)
		return;

	switch (drag.mode) {
	case CORE_DRAG_STRETCH:
		drag_stretch(x, y, keep_aspect, snap_distance, feedback);
		break;
	case CORE_DRAG_CROP:
		drag_crop(x, y);
		break;
	case CORE_DRAG_ROTATE:
		drag_rotate(x, y);
		break;
	default:
		drag_move(x, y, snap_distance, feedback);
		break;
	}
	feedback->rotation = obs_sceneitem_get_rot(drag.item);
}

void core_scene_item_drag_end(void)
{
	if (!drag.item)
		return;

	struct obs_sceneitem_crop crop;
	struct vec2 pos, scale;
	obs_sceneitem_get_crop(drag.item, &crop);
	obs_sceneitem_get_pos(drag.item, &pos);
	obs_sceneitem_get_scale(drag.item, &scale);
	static const char *modes[] = {"move", "stretch", "crop", "rotate"};
	blog(LOG_INFO, "[app] item transform (%s): pos %.0f,%.0f scale %.3f,%.3f rot %.1f crop %d,%d,%d,%d",
	     modes[drag.mode >= 0 && drag.mode <= 3 ? drag.mode : 0], pos.x, pos.y, scale.x, scale.y,
	     obs_sceneitem_get_rot(drag.item), crop.left, crop.top, crop.right, crop.bottom);
	obs_sceneitem_release(drag.item);
	drag.item = NULL;
}

bool core_scene_item_get_transform(int64_t id, struct core_item_transform *transform)
{
	memset(transform, 0, sizeof(*transform));
	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return false;

	struct vec2 pos, scale, bounds;
	struct obs_sceneitem_crop crop;
	obs_sceneitem_get_pos(item, &pos);
	obs_sceneitem_get_scale(item, &scale);
	obs_sceneitem_get_bounds(item, &bounds);
	obs_sceneitem_get_crop(item, &crop);
	obs_source_t *source = obs_sceneitem_get_source(item);

	transform->pos_x = pos.x;
	transform->pos_y = pos.y;
	transform->rot = obs_sceneitem_get_rot(item);
	transform->scale_x = scale.x;
	transform->scale_y = scale.y;
	transform->alignment = obs_sceneitem_get_alignment(item);
	transform->bounds_type = (int)obs_sceneitem_get_bounds_type(item);
	transform->bounds_x = bounds.x;
	transform->bounds_y = bounds.y;
	transform->crop_left = crop.left;
	transform->crop_top = crop.top;
	transform->crop_right = crop.right;
	transform->crop_bottom = crop.bottom;
	transform->source_width = obs_source_get_width(source);
	transform->source_height = obs_source_get_height(source);
	const struct vec2 size = item_size(item);
	transform->width = size.x;
	transform->height = size.y;
	obs_sceneitem_release(item);
	return true;
}

void core_scene_item_set_transform(int64_t id, const struct core_item_transform *transform)
{
	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return;

	struct obs_sceneitem_crop crop = {
		.left = transform->crop_left < 0 ? 0 : transform->crop_left,
		.top = transform->crop_top < 0 ? 0 : transform->crop_top,
		.right = transform->crop_right < 0 ? 0 : transform->crop_right,
		.bottom = transform->crop_bottom < 0 ? 0 : transform->crop_bottom,
	};
	struct vec2 pos = {transform->pos_x, transform->pos_y};
	struct vec2 scale = {transform->scale_x, transform->scale_y};
	struct vec2 bounds = {fmaxf(transform->bounds_x, 1.0f), fmaxf(transform->bounds_y, 1.0f)};

	obs_sceneitem_defer_update_begin(item);
	obs_sceneitem_set_crop(item, &crop);
	obs_sceneitem_set_rot(item, transform->rot);
	if (obs_sceneitem_get_bounds_type(item) != OBS_BOUNDS_NONE)
		obs_sceneitem_set_bounds(item, &bounds);
	else if (fabsf(scale.x) >= 0.001f && fabsf(scale.y) >= 0.001f)
		obs_sceneitem_set_scale(item, &scale);
	obs_sceneitem_set_pos(item, &pos);
	obs_sceneitem_defer_update_end(item);

	blog(LOG_INFO, "[app] item transform (edit): pos %.0f,%.0f rot %.1f crop %d,%d,%d,%d", pos.x, pos.y,
	     transform->rot, crop.left, crop.top, crop.right, crop.bottom);
	obs_sceneitem_release(item);
}

// 바꾸기 전과 후의 상자 가운데가 같도록 pos를 옮긴다
static void keep_center(obs_sceneitem_t *item, struct vec2 before)
{
	const struct vec2 after = box_center(item);
	struct vec2 pos;
	obs_sceneitem_get_pos(item, &pos);
	pos.x += before.x - after.x;
	pos.y += before.y - after.y;
	obs_sceneitem_set_pos(item, &pos);
}

void core_scene_item_set_rotation(int64_t id, float degrees)
{
	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return;
	const struct vec2 center = box_center(item);
	float angle = fmodf(degrees, 360.0f);
	if (angle < 0.0f)
		angle += 360.0f;
	obs_sceneitem_set_rot(item, angle);
	keep_center(item, center);
	obs_sceneitem_release(item);
}

void core_scene_item_flip(int64_t id, bool horizontal)
{
	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return;
	const struct vec2 center = box_center(item);
	struct vec2 scale;
	obs_sceneitem_get_scale(item, &scale);
	if (horizontal)
		scale.x = -scale.x;
	else
		scale.y = -scale.y;
	obs_sceneitem_set_scale(item, &scale);
	keep_center(item, center);
	obs_sceneitem_release(item);
}

// 자르기 전 원본 전체의 네 모서리 (자르기 모드에서 잘린 부분을 점선으로). 바운드 항목이나 자르지 않았으면 false
bool core_scene_item_uncropped_box(int64_t id, float corners[8])
{
	obs_sceneitem_t *item = find_item(id);
	if (!item)
		return false;

	struct obs_sceneitem_crop crop;
	obs_sceneitem_get_crop(item, &crop);
	obs_source_t *source = obs_sceneitem_get_source(item);
	const float cw = (float)((int)obs_source_get_width(source) - crop.left - crop.right);
	const float ch = (float)((int)obs_source_get_height(source) - crop.top - crop.bottom);
	const bool cropped = crop.left || crop.top || crop.right || crop.bottom;
	if (!cropped || cw <= 0.0f || ch <= 0.0f || obs_sceneitem_get_bounds_type(item) != OBS_BOUNDS_NONE) {
		obs_sceneitem_release(item);
		return false;
	}

	struct matrix4 transform;
	obs_sceneitem_get_box_transform(item, &transform);
	const float x0 = -crop.left / cw, y0 = -crop.top / ch, x1 = 1.0f + crop.right / cw, y1 = 1.0f + crop.bottom / ch;
	const float unit[4][2] = {{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}};
	for (int i = 0; i < 4; i++) {
		struct vec3 corner = transformed(unit[i][0], unit[i][1], &transform);
		corners[i * 2] = corner.x;
		corners[i * 2 + 1] = corner.y;
	}
	obs_sceneitem_release(item);
	return true;
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
		const bool have_video = obs_get_video_info(&ovi) && ovi.fps_den;
		capture_configure_camera(settings, camera_id, width, height, have_video ? ovi.fps_num : 60,
					 have_video ? ovi.fps_den : 1);
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

	// 텍스트는 글자 크기 그대로 둔다 (캔버스에 맞추면 짧은 글이 크게 늘어난다). 채팅도 설정한 상자 크기 그대로
	if (strcmp(type_id, "ios_text_source") != 0 && strcmp(type_id, "ios_chat_source") != 0)
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
		const uint32_t fps_num = have_video ? ovi.fps_num : 60;
		const uint32_t fps_den = have_video ? ovi.fps_den : 1;

		if (obs_data_has_user_value(changes, "device")) {
			capture_configure_camera(settings, obs_data_get_string(changes, "device"), width, height, fps_num,
						 fps_den);
		} else if (obs_data_has_user_value(changes, "supported_format") &&
			   !obs_data_has_user_value(changes, "frame_rate")) {
			// 입력 형식을 바꾸면 fps를 그 형식이 지원하는 값 중 캔버스에 가까운 것으로
			capture_fit_frame_rate(settings, fps_num, fps_den);
		} else if (obs_data_has_user_value(changes, "use_preset") && !obs_data_get_bool(changes, "use_preset") &&
			   !*obs_data_get_string(settings, "supported_format")) {
			// 프리셋을 끄면 고른 형식이 없으니 캔버스에 맞는 형식을 고른다
			char *device = bstrdup(obs_data_get_string(settings, "device"));
			capture_configure_camera(settings, device, width, height, fps_num, fps_den);
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
