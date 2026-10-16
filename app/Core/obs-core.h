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
	float audio_peak_db;           // 오디오 입력의 최근 피크 (dBFS, 무음이면 -inf)
};

enum core_device_kind {
	CORE_DEVICE_CAMERA = 0,
	CORE_DEVICE_AUDIO_INPUT = 1,
};

// 로그를 path 파일과 표준 출력에 남긴다. 이전 파일은 path.prev로 옮긴다. 가장 먼저 부른다.
void core_log_open(const char *path);
// 앱(Swift) 로그를 같은 곳에 남긴다
void core_log(const char *message);

// libobs를 시작하고 테스트 씬(색상 소스 + 이미지 소스 + 움직이는 막대)을 출력에 건다.
// resource_path는 앱 번들의 리소스 경로.
bool core_startup(const char *resource_path, uint32_t width, uint32_t height, uint32_t fps);

// 카메라 소스와 오디오 입력 소스를 만든다. 권한 요청이 끝난 뒤에 부른다.
void core_start_capture(void);

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
	int record_stop_code;           // 마지막으로 멈춘 이유 (OBS_OUTPUT_*, 0이면 정상)

	bool streaming;
	bool stream_reconnecting;
	double streaming_seconds;
	uint64_t stream_bytes;
	int stream_dropped_frames;      // 네트워크가 못 따라가 버린 프레임
	int stream_total_frames;
	float stream_congestion;        // 0~1
	int stream_stop_code;

	uint32_t encoder_skipped_frames; // 인코더가 못 따라가 건너뛴 프레임 (전체 출력 기준)
	uint32_t video_total_frames;
};

// 녹화(HEVC, Hybrid MP4). path의 폴더는 미리 만들어 둔다. HEVC가 안 되면 H.264로 녹화한다.
bool core_recording_start(const char *path);
// force: 인코더가 밀려 보통 멈춤이 끝나지 않을 때 남은 패킷을 버리고 바로 멈춘다
void core_recording_stop(bool force);

// RTMP/RTMPS 송출 (H.264 CBR + AAC 160kbps). 연결은 비동기로 하고 결과는 상태와 마지막 오류로 본다.
bool core_streaming_start(const char *server, const char *key, int video_kbps);
void core_streaming_stop(bool force);

void core_get_output_stats(struct core_output_stats *stats);
// 녹화(false)나 송출(true)의 마지막 오류 문장. 없으면 "". core_free로 해제한다.
char *core_output_last_error(bool stream);

// CAMetalLayer 기반 UIView에 프리뷰를 붙인다. 메인 스레드에서 호출해야 한다.
void *core_display_create(void *view, uint32_t width, uint32_t height);
void core_display_resize(void *display, uint32_t width, uint32_t height);
void core_display_destroy(void *display);

void core_get_stats(struct core_stats *stats);
