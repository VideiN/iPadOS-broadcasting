# (앱 이름 미정)

OBS Studio의 libobs 코어를 이용한 iPadOS용 방송/녹화 앱. 개인 사용 목적이며 App Store에 배포하지 않습니다.

> Based on OBS Studio (GPLv2+). Not affiliated with or endorsed by the OBS Project.

## 상태

초기 단계. libobs iOS 빌드 작업 전입니다.

## 구성

| 경로 | 내용 |
|---|---|
| `obs-studio/` | [OBS Studio](https://github.com/obsproject/obs-studio) 32.2.2 (`ba2f32b`) 소스. iPadOS용 수정은 여기서 직접 함. 원본과의 차이는 `git diff 12b487e -- obs-studio`로 확인 |

## 설치

Release에 올라가는 IPA는 fake-signed(ad-hoc) 빌드라 그대로 설치할 수 없습니다. LiveContainer 등으로 재서명해서 실행하세요.

## 라이선스

GPL-2.0-or-later. 전문은 [LICENSE](LICENSE)에 있습니다.
