// 카메라 소스(mac-avcapture) 설정 도우미. AVFoundation이 필요해 Objective-C로 구현한다.

#pragma once

#include <obs.h>

#include <stdint.h>

// 처음 쓸 카메라: 외부(UVC) 장치 → 후면 광각 → 처음 찾은 장치. 없으면 NULL. bfree로 해제한다.
char *capture_default_camera_id(void);

// 새 카메라 소스에 쓸 카메라: used(장치 id used_count개)에 없는 것 중 외부 → 후면 → 전면 → 나머지.
// 모두 쓰는 중이면 capture_default_camera_id. bfree로 해제한다.
char *capture_unused_camera_id(const char *const *used, size_t used_count);

// 연결된 카메라 목록을 core_list_devices와 같은 "id\t이름\t1\n" 줄로 (씬에 카메라 소스가 없을 때 쓴다). bfree로 해제한다.
char *capture_camera_list(void);

// settings에 장치와 형식을 넣는다. 캔버스 해상도와 fps에 맞는 형식을 고르고(use_preset=false),
// 맞는 것이 없으면 High 프리셋으로 둔다.
// fps는 캔버스 fps (fps_num/fps_den). 형식이 그 값을 지원하면 그대로, 아니면 형식의 값으로.
void capture_configure_camera(obs_data_t *settings, const char *device_id, uint32_t width, uint32_t height,
			      uint32_t fps_num, uint32_t fps_den);

// 사용자가 입력 형식(supported_format)을 바꿨을 때 fps를 맞춘다: 형식이 캔버스 fps(fps_num/fps_den)를
// 지원하면 그대로, 아니면 그 이하에서 가장 높은 값, 그것도 없으면 형식에서 가장 낮은 값.
void capture_fit_frame_rate(obs_data_t *settings, uint32_t fps_num, uint32_t fps_den);
