"""크래시 리포트(.ips)에서 크래시가 난 스레드의 스택만 뽑아 출력한다.

사용법: python3 print-crash-reports.py <리포트 디렉터리> [파일 이름 패턴]
시뮬레이터에서 죽은 프로세스의 리포트는 호스트의 ~/Library/Logs/DiagnosticReports에 남는다.
"""

import glob
import json
import os
import sys


def print_report(path):
    print(f"=== {os.path.basename(path)}")
    with open(path, encoding="utf-8") as f:
        text = f.read()

    # .ips 파일은 한 줄짜리 헤더 JSON 다음에 본문 JSON이 이어진다
    header, _, body = text.partition("\n")
    try:
        report = json.loads(body)
    except json.JSONDecodeError:
        print(text)
        return

    exception = report.get("exception", {})
    print(f"exception: {exception.get('type')} {exception.get('signal')} {exception.get('subtype', '')}")

    images = report.get("usedImages", [])

    def print_frames(frames):
        for depth, frame in enumerate(frames):
            image = images[frame["imageIndex"]] if frame.get("imageIndex", -1) < len(images) else {}
            name = image.get("name", "?")
            symbol = frame.get("symbol", hex(frame.get("imageOffset", 0)))
            location = frame.get("symbolLocation", 0)
            source = f"  ({frame['sourceFile']}:{frame.get('sourceLine', '?')})" if "sourceFile" in frame else ""
            print(f"  {depth:2} {name:30} {symbol} + {location}{source}")

    threads = report.get("threads", [])
    for index, thread in enumerate(threads):
        if thread.get("triggered"):
            print(f"crashed thread {index} {thread.get('name', '')}")
            print_frames(thread.get("frames", []))

    # 경합을 보려면 다른 스레드가 그때 무엇을 하고 있었는지도 필요하다 (위쪽 프레임만)
    for index, thread in enumerate(threads):
        if not thread.get("triggered"):
            print(f"thread {index} {thread.get('name', '')}")
            print_frames(thread.get("frames", [])[:10])


def main():
    directory = sys.argv[1]
    pattern = sys.argv[2] if len(sys.argv) > 2 else "*"
    reports = sorted(glob.glob(os.path.join(directory, pattern + ".ips")))
    if not reports:
        print(f"no crash reports matching {pattern}.ips in {directory}")
    for path in reports:
        print_report(path)


if __name__ == "__main__":
    main()
