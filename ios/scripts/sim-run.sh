#!/usr/bin/env bash
# iOS 시뮬레이터에서 테스트 실행 파일을 돌린다.
# CMake의 CMAKE_CROSSCOMPILING_EMULATOR로 지정하면 ctest가 이 스크립트를 거쳐 테스트를 실행한다.
#
# 필요한 환경 변수: SIM_UDID (부팅된 시뮬레이터의 UDID)

set -uo pipefail

: "${SIM_UDID:?SIM_UDID is not set}"

log=$(mktemp)
marker=$(mktemp)
xcrun simctl spawn "$SIM_UDID" "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

# simctl이 종료 코드를 넘기지 못하는 경우에 대비해 출력도 확인한다
if [ "$status" -eq 0 ] && grep -qE '^\[  FAILED  \]|^FAIL - |^FAILED' "$log"; then
  status=1
fi

# 시그널로 죽었으면 크래시 리포트(.ips)를 기다렸다가 스택을 바로 출력한다.
# 가끔만 터지는 문제는 그 실행의 스택이 없으면 원인을 좁히기 어렵다.
if grep -q 'terminated with signal' "$log"; then
  reports="$HOME/Library/Logs/DiagnosticReports"
  name=$(basename "$1")
  for _ in $(seq 1 30); do
    report=$(find "$reports" -maxdepth 1 -name "$name-*.ips" -newer "$marker" 2>/dev/null | head -1)
    if [ -n "$report" ]; then
      sleep 1
      python3 "$(dirname "$0")/print-crash-reports.py" "$reports" "$(basename "$report" .ips)"
      break
    fi
    sleep 1
  done
  [ -z "${report:-}" ] && echo "no crash report for $name appeared in $reports"
fi

rm -f "$log" "$marker"
exit "$status"
