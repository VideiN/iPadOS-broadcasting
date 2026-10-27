// libobs와 앱(Swift) 사이의 C 브리지.
// libobs 호출은 여기로 모으고, Swift는 이 헤더의 함수만 쓴다.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <IOSurface/IOSurfaceRef.h>

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
	float master_peak_left_db;     // 송출·녹화로 나가는 섞은 소리(트랙 1, 마스터 볼륨 뒤)의 피크 (P13)
	float master_peak_right_db;
};

enum core_device_kind {
	CORE_DEVICE_CAMERA = 0,
	CORE_DEVICE_AUDIO_INPUT = 1,
};

// 로그를 path 파일과 표준 출력에 남긴다. 이전 파일은 path.prev로 옮긴다. 가장 먼저 부른다.
void core_log_open(const char *path);
// 앱(Swift) 로그를 같은 곳에 남긴다
void core_log(const char *message);

// 캔버스 색 (P11). colorspace는 enum video_colorspace(1 Rec.601, 2 Rec.709, 3 sRGB),
// range는 enum video_range_type(1 제한, 2 전체). core_startup 전이나 core_reset_canvas 전에 부른다
void core_set_canvas_color(int colorspace, int range);
// 오디오 출력 형식 (P11). core_startup 전에만 바꿀 수 있다 (44100·48000, 1 모노·2 스테레오)
void core_set_audio_format(uint32_t sample_rate, int channels);
// 오디오 버퍼링 (P13). fixed면 처음 필요할 때 max_ms까지 한 번에 늘고 그 뒤로는 그대로(지연이 굳지 않음),
// 아니면 libobs 기본(소스가 늦을 때마다 늘어 최대 약 960ms). core_startup 전에만
void core_set_audio_buffering(bool fixed, uint32_t max_ms);

// libobs를 시작한다 (모듈, 오디오, 비디오). 씬은 core_start_capture가 불러오거나 만든다.
// resource_path는 앱 번들의 리소스 경로.
// fps는 분수 (fps_num/fps_den, 예: 30000/1001 = 29.97)
bool core_startup(const char *resource_path, uint32_t width, uint32_t height, uint32_t fps_num, uint32_t fps_den);

// 씬 구성(collection_path, JSON)을 불러오고 전역 오디오 입력을 건다. 구성이 없으면 기본 씬(배경 + 카메라)을 만든다.
// 권한 요청이 끝난 뒤에 부른다.
void core_start_capture(const char *collection_path);
// 지금 씬 구성을 core_start_capture에 준 파일에 저장한다
bool core_save_collection(void);
// 전역 오디오 입력 소스의 이름 (믹서·속성에서 쓴다)
const char *core_audio_input_name(void);
// 전역 오디오 입력의 엔진을 멈추고 오디오 세션을 끈다 (P13: 출력 없이 백그라운드로 갈 때 마이크를 놓아 앱이 잠들게)
void core_audio_input_set_suspended(bool suspended);

// --- 씬·소스 (scenes.c) ---
// 씬은 이름, 씬 항목은 id(obs_sceneitem_get_id), 소스는 이름으로 가리킨다. JSON은 core_free로 해제한다.

// {"current": "…", "scenes": [{"name": "…"}]}
char *core_scenes_json(void);
bool core_scene_add(const char *name);           // 만들고 그 씬으로 전환
bool core_scene_remove(const char *name);        // 씬은 하나 이상 남긴다
bool core_scene_rename(const char *name, const char *new_name);
void core_scene_set_current(const char *name);
void core_scene_move(const char *name, int offset); // 목록 안에서 위(-1)·아래(+1)로
// 자리 비움 (P13): 백그라운드 동안 프로그램 출력만 바꾼다 (현재 씬·목록은 그대로). scene_name이 비면 자동 화면
// (짙은 바탕 + image_path 이미지, 없으면 text 글자). 그 밖은 그 이름의 씬. core_away_end가 현재 씬으로 되돌린다
bool core_away_begin(const char *scene_name, const char *image_path, const char *text);
void core_away_end(void);
bool core_away_active(void);

// 현재 씬의 항목, 위에 있는 것부터: {"items": [{"id", "name", "type", "visible", "locked", "video", "audio"}]}
char *core_scene_items_json(void);
// 항목의 네 모서리(캔버스 좌표, 왼쪽 위부터 시계 방향 x,y 4쌍)
bool core_scene_item_box(int64_t id, float corners[8]);
// 캔버스의 한 점에 있는 맨 위 항목 (보이고 잠기지 않은 것). 없으면 -1
int64_t core_scene_item_at(float x, float y);
void core_scene_item_translate(int64_t id, float dx, float dy);
void core_scene_item_scale(int64_t id, float factor, float cx, float cy);
void core_scene_item_fit(int64_t id);   // 캔버스에 맞추기
void core_scene_item_reset(int64_t id); // 원래 크기, 왼쪽 위, 회전·자르기 없음

// 미리보기 편집 (P11). 핸들은 항목 좌표의 변(왼쪽·오른쪽·위·아래 비트, 모서리는 둘을 함께)
enum core_item_handle {
	CORE_HANDLE_LEFT = 1,
	CORE_HANDLE_RIGHT = 2,
	CORE_HANDLE_TOP = 4,
	CORE_HANDLE_BOTTOM = 8,
};
enum core_drag_mode { CORE_DRAG_MOVE = 0, CORE_DRAG_STRETCH = 1, CORE_DRAG_CROP = 2, CORE_DRAG_ROTATE = 3 };

struct core_drag_feedback {
	float rotation; // 지금 회전 (도)
	bool snap_x;    // 캔버스 세로선(x = guide_x)에 붙었다
	float guide_x;
	bool snap_y;    // 캔버스 가로선(y = guide_y)에 붙었다
	float guide_y;
};

// 끌기를 시작한다 (x, y: 손가락의 캔버스 좌표). 잠긴 항목이면 false
bool core_scene_item_drag_begin(int64_t id, int mode, int handle, float x, float y);
// keep_aspect: 모서리를 끌 때 비율 유지. snap_distance: 캔버스 가장자리·가운데선에 붙는 거리 (0이면 안 붙음)
void core_scene_item_drag_to(float x, float y, bool keep_aspect, float snap_distance,
			     struct core_drag_feedback *feedback);
void core_scene_item_drag_end(void); // 결과를 로그에 남긴다

struct core_item_transform {
	float pos_x, pos_y;   // 정렬점의 캔버스 좌표
	float rot;            // 도
	float scale_x, scale_y; // 음수면 뒤집힘
	uint32_t alignment;
	int bounds_type;      // OBS_BOUNDS_NONE(0)이 아니면 크기는 bounds
	float bounds_x, bounds_y;
	int crop_left, crop_top, crop_right, crop_bottom;
	uint32_t source_width, source_height;
	float width, height;  // 보이는 크기 (읽기 전용)
};
bool core_scene_item_get_transform(int64_t id, struct core_item_transform *transform);
void core_scene_item_set_transform(int64_t id, const struct core_item_transform *transform);
void core_scene_item_set_rotation(int64_t id, float degrees); // 상자 가운데를 기준으로
void core_scene_item_flip(int64_t id, bool horizontal);       // 상자 가운데를 기준으로
// 자르기 전 원본 전체의 네 모서리 (core_scene_item_box와 같은 순서). 자르지 않았거나 바운드 항목이면 false
bool core_scene_item_uncropped_box(int64_t id, float corners[8]);
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
	int record_stop_count;          // 녹화가 멈춘 횟수 (늘면 방금 멈춘 것, P13)

	bool streaming;
	bool stream_reconnecting;
	double stream_reconnect_seconds; // 재연결을 시작한 뒤 지난 초 (재연결 중일 때만)
	double streaming_seconds;
	uint64_t stream_bytes;
	int stream_dropped_frames;      // 네트워크가 못 따라가 버린 프레임
	int stream_total_frames;
	float stream_congestion;        // 0~1
	int stream_stop_code;
	int stream_stop_count;          // 송출이 멈춘 횟수 (연결 실패 포함, P13)
	int stream_start_count;         // 송출이 시작된 횟수 (재연결은 세지 않음, P13)

	bool replay_active;
	uint64_t replay_bytes;          // 지금 메모리에 든 리플레이 크기
	int replay_saved_count;         // 지금까지 저장한 리플레이 수 (늘면 새로 저장된 것)

	uint32_t encoder_skipped_frames; // 인코더가 못 따라가 건너뛴 프레임 (전체 출력 기준)
	uint32_t video_total_frames;
};

// 인코딩 설정 (P11). VideoToolbox(H.264/HEVC)와 AudioToolbox AAC의 obs 설정으로 옮긴다
enum core_codec { CORE_CODEC_H264 = 0, CORE_CODEC_HEVC = 1 };
enum core_rate_control { CORE_RC_CBR = 0, CORE_RC_ABR = 1, CORE_RC_CRF = 2 };
enum core_profile { CORE_PROFILE_AUTO = 0, CORE_PROFILE_BASELINE = 1, CORE_PROFILE_MAIN = 2, CORE_PROFILE_HIGH = 3 };

struct core_video_encoding {
	int codec;                 // enum core_codec
	int rate_control;          // enum core_rate_control
	int bitrate_kbps;
	int quality;               // CRF일 때 0~100
	bool limit_bitrate;        // ABR·CRF의 최대 비트레이트 제한
	int max_bitrate_kbps;
	double max_bitrate_window; // 초
	int keyint_sec;            // 키프레임 간격 (1 미만이면 2초)
	int profile;               // enum core_profile (H.264만, HEVC는 main)
	bool bframes;
	uint32_t width;            // 출력 크기. 0이면 캔버스 크기 그대로
	uint32_t height;
	int scale_type;            // 출력 크기가 다를 때 GPU 스케일 필터 (enum obs_scale_type)
};

struct core_audio_encoding {
	int bitrate_kbps;
	bool he_aac; // 낮은 비트레이트에서 HE-AAC를 허용
};

// 송출 연결 옵션 (P11)
struct core_stream_options {
	bool dyn_bitrate; // 네트워크가 막히면 비트레이트를 낮췄다 되돌린다 (RTMP만)
	bool reconnect;
	int retries;
	int retry_sec;
	int delay_sec;    // 송출 지연. 0보다 크면 dyn_bitrate는 꺼진다 (rtmp-stream.c)
};

// 리플레이 버퍼: 마지막 seconds초(최대 max_mb MB)를 메모리에 두고, 저장하면 directory에 "Replay 날짜 시각.mp4"로 쓴다.
// 녹화 인코더를 같이 쓴다 (녹화 중이면 녹화 인코딩 그대로).
bool core_replay_start(const char *directory, int seconds, int max_mb, const struct core_video_encoding *video,
		       const struct core_audio_encoding *audio);
void core_replay_stop(void);
void core_replay_save(void); // 비동기. 끝나면 replay_saved_count가 늘고 core_replay_last_path가 바뀐다
char *core_replay_last_path(void); // core_free로 해제한다

// 녹화(Hybrid MP4). path의 폴더는 미리 만들어 둔다. 그 코덱의 인코더를 쓸 수 없으면 H.264로 녹화한다.
bool core_recording_start(const char *path, const struct core_video_encoding *video,
			  const struct core_audio_encoding *audio);
// force: 인코더가 밀려 보통 멈춤이 끝나지 않을 때 남은 패킷을 버리고 바로 멈춘다
void core_recording_stop(bool force);

// RTMP/RTMPS/SRT 송출. HEVC는 Enhanced RTMP (받는 쪽이 지원해야 함).
// 연결은 비동기로 하고 결과는 상태와 마지막 오류로 본다.
bool core_streaming_start(const char *server, const char *key, const struct core_video_encoding *video,
			  const struct core_audio_encoding *audio, const struct core_stream_options *options);
void core_streaming_stop(bool force);
bool core_outputs_active(void);

// 캔버스(해상도·fps)를 바꾼다. 녹화·송출 중이면 바꾸지 않고 false
bool core_reset_canvas(uint32_t width, uint32_t height, uint32_t fps_num, uint32_t fps_den);

void core_get_output_stats(struct core_output_stats *stats);
// 녹화(false)나 송출(true)의 마지막 오류 문장. 없으면 "". core_free로 해제한다.
char *core_output_last_error(bool stream);

// CAMetalLayer 기반 UIView에 프리뷰를 붙인다. 메인 스레드에서 호출해야 한다.
void *core_display_create(void *view, uint32_t width, uint32_t height);
void core_display_resize(void *display, uint32_t width, uint32_t height);
void core_display_destroy(void *display);

void core_get_stats(struct core_stats *stats);
// 오디오 입력의 최근 피크 L/R만 (core_stats의 값과 같다). 오디오 독의 미터가 자주 부른다
void core_audio_input_peak(float *left_db, float *right_db);
// 섞은 소리(트랙 1, 마스터 볼륨 뒤)의 최근 피크 L/R (P13)
void core_master_peak(float *left_db, float *right_db);
// 마스터 볼륨 (배수, 1 = 그대로). core_startup 전에 불러도 되고, 그 뒤에는 바로 바뀐다 (P13)
void core_set_master_volume(float multiplier);
float core_master_volume(void);

// --- 채팅 소스 (P7, plugins/ios-chat의 proc handler) ---
// 메인 스레드에서 부른다. libobs가 아직 안 떴으면 아무것도 하지 않는다.

// 이벤트 JSON 배열(add/remove/removeAuthor, ios-chat.m 참고)을 YouTube 채팅 소스들에 보낸다
void core_chat_push(const char *json);
// 채팅 소스 속성 화면에 보일 상태 줄
void core_chat_set_status(const char *text);
// YouTube 채팅을 보여 주는 채팅 소스 수
int core_chat_listeners(void);

// --- 아이폰 마이크 (P13, facelink-audio-source.c ↔ FaceLink.swift) ---
// FaceLink 소리 패킷(PCM s16, 섞인 채널)을 "아이폰 마이크" 소스들에 넘긴다. 어느 스레드에서나
void core_facelink_audio_push(uint32_t sequence, uint32_t rate, int channels, const int16_t *pcm, int frames);
// 보내는 쪽이 멈췄을 때 (로그)
void core_facelink_audio_stopped(void);
struct core_facelink_audio_stats {
	bool receiving;
	uint32_t sample_rate;
	int channels;
	int packets;
	int lost;      // 빠진 순번 (무음으로 채움)
	int late;      // 늦게·두 번 와서 버림
	int underruns; // 버퍼가 비어 다시 채움
	int buffer_ms; // 첫 소스의 지금 버퍼
	int sources;   // 아이폰 마이크 소스 수
	float output_peak; // 최근에 낸 소리의 피크 (0~1)
};
void core_facelink_audio_get_stats(struct core_facelink_audio_stats *stats);
// 소리가 안 올 때 소스 속성에 보일 까닭 (FaceLink.swift가 받기 상태로 정한다)
void core_facelink_audio_set_hint(const char *hint);
// CI: 장면에 넣지 않은 아이폰 마이크 소스를 만들고 놓는다
void *core_facelink_audio_test_begin(void);
void core_facelink_audio_test_end(void *source);

// --- 아바타 소스 (P9, avatar-source.c ↔ Avatar.swift) ---
// VRM 모델은 앱이 IOSurface(BGRA, 미리 곱한 알파)에 그리고, 소스는 그것을 보인다. 설정은 obs_data의 JSON.
struct core_avatar_callbacks {
	// 소스를 만들 때 (어느 스레드에서나). context는 core_avatar_present에 넘기는 값. 앱 쪽 객체를 돌려준다
	void *(*create)(void *context, const char *settings_json);
	void (*update)(void *host, const char *settings_json);
	// 이것이 돌아온 뒤에는 그 context로 core_avatar_present를 부르지 않는다
	void (*destroy)(void *host);
	// 화면(프리뷰·출력) 어딘가에 보이는지
	void (*set_showing)(void *host, bool showing);
	// 속성 화면 맨 위의 상태 글 (UTF-8, 0으로 끝냄)
	void (*copy_status)(void *host, char *buffer, size_t size);
};
// core_startup 전에 부른다. 부르지 않으면 아바타 소스는 등록되지 않는다
void core_avatar_set_callbacks(const struct core_avatar_callbacks *callbacks);
// 새로 그린 표면을 보인다 (어느 스레드에서나). 소스가 쓰는 동안 표면의 use count가 올라가 있다
void core_avatar_present(void *context, IOSurfaceRef surface);
