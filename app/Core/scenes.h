// scenes.c 안쪽 함수 (obs-core.c에서 쓴다). Swift에 보이는 함수는 obs-core.h에 있다.

#pragma once

#include <obs.h>

// 저장한 씬 구성을 불러온다. 들어 있던 전역 오디오 입력 소스(참조를 더함)를 돌려준다. 없으면 NULL.
obs_source_t *scenes_load(const char *path);
bool scenes_empty(void);
// 처음 실행용 기본 씬: 배경색 + 카메라
void scenes_create_default(void);
// 현재 씬에서 맨 위의 카메라 소스 (참조를 더함). 없으면 NULL.
obs_source_t *scenes_primary_camera(void);
