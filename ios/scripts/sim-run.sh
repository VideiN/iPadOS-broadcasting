#!/usr/bin/env bash
# iOS 시뮬레이터에서 테스트 실행 파일을 돌린다.
# CMake의 CMAKE_CROSSCOMPILING_EMULATOR로 지정하면 ctest가 이 스크립트를 거쳐 테스트를 실행한다.
#
# 필요한 환경 변수: SIM_UDID (부팅된 시뮬레이터의 UDID)

set -uo pipefail

: "${SIM_UDID:?SIM_UDID is not set}"

log=$(mktemp)
xcrun simctl spawn "$SIM_UDID" "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

# simctl이 종료 코드를 넘기지 못하는 경우에 대비해 출력도 확인한다
if [ "$status" -eq 0 ] && grep -qE '^\[  FAILED  \]|^FAIL - |^FAILED' "$log"; then
  status=1
fi

rm -f "$log"
exit "$status"
