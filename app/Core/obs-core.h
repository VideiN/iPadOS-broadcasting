// libobs와 앱(Swift) 사이의 C 브리지.
// libobs 호출은 여기로 모으고, Swift는 이 헤더의 함수만 쓴다.

#pragma once

#include <stdbool.h>
#include <stdint.h>

struct core_stats {
	double active_fps;             // 실제 렌더 fps
	double target_fps;             // 설정한 출력 fps
	double frame_time_ms;          // 그래픽 스레드의 평균 프레임 렌더 시간
	double gpu_ms_per_second;      // 1초 동안의 GPU 실행 시간 합 (Metal 커맨드 버퍼 기준)
	uint32_t total_frames;         // 렌더한 프레임 수
	uint32_t lagged_frames;        // 제때 렌더하지 못한 프레임 수
	uint64_t memory_footprint;     // 프로세스 메모리 사용량 (phys_footprint, 바이트)
	uint64_t memory_available;     // 남은 메모리 한도 (os_proc_available_memory, 바이트)
	uint32_t camera_width;         // 카메라 소스의 현재 프레임 크기 (프레임이 없으면 0)
	uint32_t camera_height;
	float camera_fps;              // 카메라가 실제로 보내는 초당 프레임 (캔버스 fps보다 낮을 수 있다)
	float audio_peak_left_db;      // 오디오 입력의 최근 피크, 왼쪽·오른쪽 (dBFS, 무음이면 -inf)
	float audio_peak_right_db;
};

enum core_device_kind {
	CORE_DEVICE_CAMERA = 0,
	CORE_DEVICE_AUDIO_INPUT = 1,
};

// 로그를 path 파일과 표준 출력에 남긴다. 이전 파일은 path.prev로 옮긴다. 가장 먼저 부른다.
void core_log_open(const char *path);
// 앱(Swift) 로그를 같은 곳에 남긴다
void core_log(const char *message);

// libobs를 시작한다 (모듈, 오디오, 비디오). 씬은 core_start_capture가 불러오거나 만든다.
// resource_path는 앱 번들의 리소스 경로.
bool core_startup(const char *resource_path, uint32_t width, uint32_t height, uint32_t fps);

// 씬 구성(collection_path, JSON)을 불러오고 전역 오디오 입력을 건다. 구성이 없으면 기본 씬(배경 + 카메라)을 만든다.
// 권한 요청이 끝난 뒤에 부른다.
void core_start_capture(const char *collection_path);
// 지금 씬 구성을 core_start_capture에 준 파일에 저장한다
bool core_save_collection(void);
// 전역 오디오 입력 소스의 이름 (믹서·속성에서 쓴다)
const char *core_audio_input_name(void);

// --- 씬·소스 (scenes.c) ---
// 씬은 이름, 씬 항목은 id(obs_sceneitem_get_id), 소스는 이름으로 가리킨다. JSON은 core_free로 해제한다.

// {"current": "…", "scenes": [{"name": "…"}]}
char *core_scenes_json(void);
bool core_scene_add(const char *name);           // 만들고 그 씬으로 전환
bool core_scene_remove(const char *name);        // 씬은 하나 이상 남긴다
bool core_scene_rename(const char *name, const char *new_name);
void core_scene_set_current(const char *name);
void core_scene_move(const char *name, int offset); // 목록 안에서 위(-1)·아래(+1)로

// 현재 씬의 항목, 위에 있는 것부터: {"items": [{"id", "name", "type", "visible", "locked", "video", "audio"}]}
char *core_scene_items_json(void);
// 항목의 네 모서리(캔버스 좌표, 왼쪽 위부터 시계 방향 x,y 4쌍)
bool core_scene_item_box(int64_t id, float corners[8]);
// 캔버스의 한 점에 있는 맨 위 항목 (보이고 잠기지 않은 것). 없으면 -1
int64_t core_scene_item_at(float x, float y);
void core_scene_item_translate(int64_t id, float dx, float dy);
void core_scene_item_scale(int64_t id, float factor, float cx, float cy);
void core_scene_item_fit(int64_t id);   // 캔버스에 맞추기
void core_scene_item_reset(int64_t id); // 원래 크기, 왼쪽 위
void core_scene_item_set_visible(int64_t id, bool visible);
void core_scene_item_set_locked(int64_t id, bool locked);
void core_scene_item_order(int64_t id, int movement); // 0 위로, 1 아래로, 2 맨 위, 3 맨 아래 (enum obs_order_movement)
void core_scene_item_remove(int64_t id);

// 추가할 수 있는 소스 종류: {"types": [{"id", "name"}]}
char *core_source_types_json(void);
// 현재 씬에 소스를 새로 넣는다 (영상 소스는 캔버스에 맞춤). 항목 id, 실패하면 -1
int64_t core_scene_add_source(const char *type_id, const char *name);

// 소스 속성: {"type", "properties": [...], "settings": {...기본값 포함}}
char *core_source_properties_json(const char *source_name);
// 바뀐 설정만 담은 JSON을 덮어쓴다 (카메라 장치를 바꾸면 형식도 다시 고름)
void core_source_update(const char *source_name, const char *changes_json);
void core_source_press_button(const char *source_name, const char *property_name);
bool core_source_rename(const char *source_name, const char *new_name);
void core_source_set_volume(const char *source_name, float multiplier);
void core_source_set_muted(const char *source_name, bool muted);
float core_source_volume(const char *source_name);
bool core_source_muted(const char *source_name);

// 미디어 소스 조작. action: 0 재생/일시정지 전환, 1 처음부터, 2 정지. 조작 뒤 상태(enum obs_media_state)를 돌려준다
int core_source_media(const char *source_name, int action);

// 오디오 필터. 필터의 속성은 "소스 이름" + 0x1F + "필터 이름"을 core_source_properties_json·core_source_update·
// core_source_press_button에 넘겨 다룬다. 필터는 씬 구성 저장에 함께 들어간다 (obs_save_sources).
char *core_filter_types_json(const char *source_name); // {"types": [{"id", "name"}]}, 소리 없는 소스면 비어 있음
char *core_filters_json(const char *source_name);      // {"filters": [{"name", "id", "type_name", "enabled"}]}
bool core_filter_add(const char *source_name, const char *type_id);
void core_filter_remove(const char *source_name, const char *filter_name);
void core_filter_set_enabled(const char *source_name, const char *filter_name, bool enabled);
void core_filter_move(const char *source_name, const char *filter_name, int direction); // -1 위로, +1 아래로

bool core_collection_save(const char *path, const char *audio_input_name);

// 장치 목록을 "id\t이름\t연결(1/0)\n" 줄로 돌려준다. 연결 0은 고른 장치가 빠져 있는 경우다.
// 오디오 입력의 id ""는 시스템 기본 경로. core_free로 해제한다.
char *core_list_devices(enum core_device_kind kind);
// 지금 고른 장치 id. core_free로 해제한다.
char *core_current_device(enum core_device_kind kind);
// 장치를 바꾼다. 카메라는 캔버스에 맞는 형식을 함께 고른다.
void core_select_device(enum core_device_kind kind, const char *device_id);
void core_free(void *ptr);

// --- 녹화·송출 (outputs.c) ---

struct core_output_stats {
	bool recording;
	double recording_seconds;
	uint64_t recording_bytes;
	int record_total_frames;        // 녹화 파일에 들어간 비디오 프레임 (초당 증가량 = 실제 fps)
	int record_stop_code;           // 마지막으로 멈춘 이유 (OBS_OUTPUT_*, 0이면 정상)

	bool streaming;
	bool stream_reconnecting;
	double streaming_seconds;
	uint64_t stream_bytes;
	int stream_dropped_frames;      // 네트워크가 못 따라가 버린 프레임
	int stream_total_frames;
	float stream_congestion;        // 0~1
	int stream_stop_code;

	bool replay_active;
	uint64_t replay_bytes;          // 지금 메모리에 든 리플레이 크기
	int replay_saved_count;         // 지금까지 저장한 리플레이 수 (늘면 새로 저장된 것)

	uint32_t encoder_skipped_frames; // 인코더가 못 따라가 건너뛴 프레임 (전체 출력 기준)
	uint32_t video_total_frames;
};

// 리플레이 버퍼: 마지막 seconds초를 메모리에 두고, 저장하면 directory에 "Replay 날짜 시각.mp4"로 쓴다.
// 녹화 인코더를 같이 쓴다 (녹화 중이면 녹화 코덱·비트레이트 그대로).
bool core_replay_start(const char *directory, int seconds, const char *codec, int video_kbps, int audio_kbps);
void core_replay_stop(void);
void core_replay_save(void); // 비동기. 끝나면 replay_saved_count가 늘고 core_replay_last_path가 바뀐다
char *core_replay_last_path(void); // core_free로 해제한다

// 녹화(Hybrid MP4, 비디오 ABR + AAC). codec은 "hevc"·"h264". path의 폴더는 미리 만들어 둔다.
// 그 코덱의 인코더를 쓸 수 없으면 H.264로 녹화한다.
bool core_recording_start(const char *path, const char *codec, int video_kbps, int audio_kbps);
// force: 인코더가 밀려 보통 멈춤이 끝나지 않을 때 남은 패킷을 버리고 바로 멈춘다
void core_recording_stop(bool force);

// RTMP/RTMPS 송출 (비디오 CBR + AAC). codec "hevc"는 Enhanced RTMP (받는 쪽이 지원해야 함).
// 연결은 비동기로 하고 결과는 상태와 마지막 오류로 본다.
bool core_streaming_start(const char *server, const char *key, const char *codec, int video_kbps, int audio_kbps);
void core_streaming_stop(bool force);
bool core_outputs_active(void);

// 캔버스(해상도·fps)를 바꾼다. 녹화·송출 중이면 바꾸지 않고 false
bool core_reset_canvas(uint32_t width, uint32_t height, uint32_t fps);

void core_get_output_stats(struct core_output_stats *stats);
// 녹화(false)나 송출(true)의 마지막 오류 문장. 없으면 "". core_free로 해제한다.
char *core_output_last_error(bool stream);

// CAMetalLayer 기반 UIView에 프리뷰를 붙인다. 메인 스레드에서 호출해야 한다.
void *core_display_create(void *view, uint32_t width, uint32_t height);
void core_display_resize(void *display, uint32_t width, uint32_t height);
void core_display_destroy(void *display);

void core_get_stats(struct core_stats *stats);

// --- 채팅 소스 (P7, plugins/ios-chat의 proc handler) ---
// 메인 스레드에서 부른다. libobs가 아직 안 떴으면 아무것도 하지 않는다.

// 이벤트 JSON 배열(add/remove/removeAuthor, ios-chat.m 참고)을 YouTube 채팅 소스들에 보낸다
void core_chat_push(const char *json);
// 채팅 소스 속성 화면에 보일 상태 줄
void core_chat_set_status(const char *text);
// YouTube 채팅을 보여 주는 채팅 소스 수
int core_chat_listeners(void);
