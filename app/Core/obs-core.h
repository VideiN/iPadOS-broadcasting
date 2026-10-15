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
};

// libobs를 시작하고 테스트 씬(색상 소스 + 이미지 소스 + 움직이는 막대)을 출력에 건다.
// resource_path는 앱 번들의 리소스 경로.
bool core_startup(const char *resource_path, uint32_t width, uint32_t height, uint32_t fps);

// CAMetalLayer 기반 UIView에 프리뷰를 붙인다. 메인 스레드에서 호출해야 한다.
void *core_display_create(void *view, uint32_t width, uint32_t height);
void core_display_resize(void *display, uint32_t width, uint32_t height);
void core_display_destroy(void *display);

void core_get_stats(struct core_stats *stats);
