#!/usr/bin/env python3
"""CI용 FaceLink v1 합성 송신기 (P9, docs/face-link.md). 아이폰 컴패니언 앱 대신 얼굴 수치를 보낸다.

앱을 `-autotest-facelink <페어링 코드>`로 띄우면 앱이 UDP 39539에서 받는다. 이 스크립트는
- 1초마다 /FaceLink/Hello, 60Hz로 프레임(/FaceLink/Frame, 머리·눈 /VMC/Ext/Bone/Pos, 블렌드셰이프 52개
  /VMC/Ext/Blend/Val, /VMC/Ext/Blend/Apply)을 1,400바이트 이하 번들로 나눠 보낸다
- 앱의 첫 /FaceLink/Ack를 받은 때(t0)부터 단계를 밟는다:
  t0+2초 깨진 패킷, 지난 순번 프레임, 다른 주소에서 틀린 코드의 Hello와 코드 없는 VMC(앱이 버려야 함)
  t0+6~8초 추적 상태 0 (얼굴 놓침), t0+10초 보내기를 멈춤 (앱은 1초 뒤 끊김으로 보고 3초 뒤 Ack를 멈춰야 함)
- t0+2초부터 또 다른 주소에서 코드 없는 Hello와 프레임("CI 허락 송신기", 아이폰 앱에서 Bonjour 목록으로 고른 경우):
  앱은 연결 요청으로 보이고, 시험이 허락하면 첫 송신기가 멈춘 뒤 이것을 받아 Ack를 보내야 함
- 앱이 보내는 /FaceLink/Calibrate(정면 맞추기)를 받으면 남긴다
- 몸 (P13): 프레임마다 왼팔(위팔·아래팔)을 흔들고 손가락을 굽히는 뼈도 보낸다. 허락 송신기가 Ack를 받은 1초 뒤부터
  8초 동안은 또 다른 주소에서 Hello 없이 몸 뼈만 보내는 VMC 앱(mocopi 같은 것, /VMC/Ext/Root/Pos + Bone/Pos,
  /VMC/Ext/OK로 끝, Blend/Apply 없음)이 된다. 앱 시험은 그때 "다른 VMC 앱 받기"를 켜고 몸을 이쪽에서 받아야 한다
- 소리 (P13, 3.8): 허락 송신기가 Ack를 받은 뒤 1 kHz 사인파를 FLAU 패킷(48 kHz 모노 PCM, 10ms)으로 보낸다.
  50번째마다 하나를 빼고, 한 번은 두 패킷의 순서를 바꾼다

사용법: facelink-sender.py <주소> <포트> <페어링 코드>
"""

import math
import random
import select
import socket
import struct
import sys
import time
import uuid

NAMES = [
    "EyeBlinkLeft", "EyeLookDownLeft", "EyeLookInLeft", "EyeLookOutLeft", "EyeLookUpLeft", "EyeSquintLeft",
    "EyeWideLeft",
    "EyeBlinkRight", "EyeLookDownRight", "EyeLookInRight", "EyeLookOutRight", "EyeLookUpRight", "EyeSquintRight",
    "EyeWideRight",
    "JawForward", "JawLeft", "JawRight", "JawOpen",
    "MouthClose", "MouthFunnel", "MouthPucker", "MouthLeft", "MouthRight", "MouthSmileLeft", "MouthSmileRight",
    "MouthFrownLeft", "MouthFrownRight", "MouthDimpleLeft", "MouthDimpleRight", "MouthStretchLeft",
    "MouthStretchRight", "MouthRollLower", "MouthRollUpper", "MouthShrugLower", "MouthShrugUpper", "MouthPressLeft",
    "MouthPressRight", "MouthLowerDownLeft", "MouthLowerDownRight", "MouthUpperUpLeft", "MouthUpperUpRight",
    "BrowDownLeft", "BrowDownRight", "BrowInnerUp", "BrowOuterUpLeft", "BrowOuterUpRight",
    "CheekPuff", "CheekSquintLeft", "CheekSquintRight", "NoseSneerLeft", "NoseSneerRight",
    "TongueOut",
]
assert len(NAMES) == 52

MAX_DATAGRAM = 1400
FPS = 60


def log(message):
    print(message, flush=True)


def osc_string(text):
    data = text.encode() + b"\0"
    return data + b"\0" * (-len(data) % 4)


def osc_message(address, *args):
    tags = ","
    payload = b""
    for arg in args:
        if isinstance(arg, bool) or isinstance(arg, int):
            tags += "i"
            payload += struct.pack(">i", int(arg))
        elif isinstance(arg, float):
            tags += "f"
            payload += struct.pack(">f", arg)
        else:
            tags += "s"
            payload += osc_string(str(arg))
    return osc_string(address) + osc_string(tags) + payload


def osc_bundles(messages):
    """메시지들을 1,400바이트 이하 번들들로 (time tag 1 = 즉시)"""
    header = b"#bundle\0" + struct.pack(">Q", 1)
    bundles, current = [], header
    for message in messages:
        element = struct.pack(">i", len(message)) + message
        if len(current) + len(element) > MAX_DATAGRAM and current != header:
            bundles.append(current)
            current = header
        current += element
    if current != header:
        bundles.append(current)
    return bundles


def parse_message(data):
    """앱이 보내는 Ack·Calibrate 읽기 (번들 아님)"""
    def string(offset):
        end = data.index(b"\0", offset)
        return data[offset:end].decode(), (end + 4) // 4 * 4
    address, offset = string(0)
    if offset >= len(data):
        return address, []
    tags, offset = string(offset)
    args = []
    for tag in tags[1:]:
        if tag == "i":
            args.append(struct.unpack(">i", data[offset:offset + 4])[0])
            offset += 4
        elif tag == "f":
            args.append(struct.unpack(">f", data[offset:offset + 4])[0])
            offset += 4
        elif tag == "s":
            value, offset = string(offset)
            args.append(value)
    return address, args


def yaw_quaternion(yaw):
    return (0.0, math.sin(yaw / 2), 0.0, math.cos(yaw / 2))


def axis_quaternion(axis, angle):
    s = math.sin(angle / 2)
    return (axis[0] * s, axis[1] * s, axis[2] * s, math.cos(angle / 2))


def body_messages(t, full=False):
    """VMC 몸 뼈 (Unity 좌표, 부모 기준 로컬 회전). 왼팔은 앞으로 들었다 내리고, 손가락은 굽혔다 편다"""
    raise_arm = axis_quaternion((0.0, 0.0, 1.0), -1.1 + 0.4 * math.sin(t * 2))
    elbow = axis_quaternion((0.0, 1.0, 0.0), 0.6 + 0.3 * math.sin(t * 3))
    curl = axis_quaternion((0.0, 0.0, 1.0), 0.5 + 0.4 * math.sin(t * 4))
    messages = [
        osc_message("/VMC/Ext/Bone/Pos", "LeftUpperArm", 0.0, 0.0, 0.0, *raise_arm),
        osc_message("/VMC/Ext/Bone/Pos", "LeftLowerArm", 0.0, 0.0, 0.0, *elbow),
    ]
    for finger in ("Index", "Middle", "Ring"):
        messages.append(osc_message("/VMC/Ext/Bone/Pos", f"Left{finger}Proximal", 0.0, 0.0, 0.0, *curl))
    if full:
        lean = axis_quaternion((1.0, 0.0, 0.0), 0.1 * math.sin(t))
        messages.insert(0, osc_message("/VMC/Ext/Root/Pos", "root", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0))
        for name in ("Hips", "Spine", "Chest", "Neck", "Head", "RightUpperArm", "RightLowerArm", "LeftUpperLeg",
                     "RightUpperLeg"):
            messages.append(osc_message("/VMC/Ext/Bone/Pos", name, 0.0, 0.0, 0.0, *lean))
    return messages


AUDIO_CACHE = {}


def audio_packet(sequence, sample_time, frames=480, rate=48000):
    """3.8 소리 패킷: 정수는 빅 엔디언, 표본은 s16 리틀 엔디언"""
    # 480표본 = 1 kHz 10주기라 매 패킷이 같다
    key = (sample_time % rate, frames, rate)
    if key not in AUDIO_CACHE:
        AUDIO_CACHE[key] = b"".join(
            struct.pack("<h", int(16000 * math.sin(2 * math.pi * 1000 * (sample_time + i) / rate)))
            for i in range(frames))
    samples = AUDIO_CACHE[key]
    header = b"FLAU" + bytes([1, 1, 1, 0]) + struct.pack(">IQIHH", sequence, sample_time, rate, frames, 0)
    return header + samples


def frame_messages(sequence, sent, tracking, t):
    head = yaw_quaternion(0.25 + 0.15 * math.sin(t))
    eye = yaw_quaternion(0.1 * math.sin(t * 2))
    messages = [
        osc_message("/FaceLink/Frame", sequence, float(sent), 1 if tracking else 0),
        osc_message("/VMC/Ext/Bone/Pos", "Head", 0.01, 0.0, 0.0, *head),
        osc_message("/VMC/Ext/Bone/Pos", "LeftEye", 0.0, 0.0, 0.0, *eye),
        osc_message("/VMC/Ext/Bone/Pos", "RightEye", 0.0, 0.0, 0.0, *eye),
    ] + body_messages(t)
    for index, name in enumerate(NAMES):
        value = 0.5 + 0.5 * math.sin(t * (1 + index * 0.05) + index)
        messages.append(osc_message("/VMC/Ext/Blend/Val", name, value))
    messages.append(osc_message("/VMC/Ext/Blend/Apply"))
    return messages


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    host, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    target = (host, port)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    rogue = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rogue.bind(("127.0.0.1", 0))
    asker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    asker.bind(("127.0.0.1", 0))
    body_only = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    body_only.bind(("127.0.0.1", 0))
    body_frames = 0
    next_body_frame = None
    audio_sequence = 0
    audio_packets = 0
    next_audio = None
    held_audio = None
    asker_session = str(uuid.uuid4())
    session = str(uuid.uuid4())
    log(f"facelink sender: to {host}:{port} from port {sock.getsockname()[1]} (session {session[:8]})")

    started = time.monotonic()
    sequence = 0
    frames = 0
    max_datagram = 0
    next_frame = started
    next_hello = started
    first_ack = None
    acks = 0
    last_ack_time = None
    calibrated = False
    extras_sent = False
    stopped_at = None
    asker_sequence = 0
    next_asker_frame = None
    next_asker_hello = None
    asker_ack = None
    failures = []

    def send(data, via=sock):
        nonlocal max_datagram
        max_datagram = max(max_datagram, len(data))
        via.sendto(data, target)

    while True:
        now = time.monotonic()
        elapsed = now - started
        since_ack = now - first_ack if first_ack is not None else None

        if first_ack is None and elapsed > 120:
            failures.append("no ack within 120 s (is the app listening?)")
            break
        if stopped_at is None and since_ack is not None and since_ack >= 10:
            stopped_at = now
            log(f"facelink sender: stopped sending after {frames} frames (t0+10 s)")
        # 허락 송신기가 Ack를 받고 몸만 보내는 단계가 끝날 때까지 (허락은 첫 송신기가 끊긴 뒤라 늦어도 25초)
        if stopped_at is not None and now - stopped_at >= 5 and (
                (asker_ack is not None and now - asker_ack >= 10) or now - stopped_at >= 35):
            break

        # 소리 (P13): 허락 송신기가 받아들여진 뒤 끝날 때까지 10ms마다
        if asker_ack is not None and next_audio is None:
            next_audio = asker_ack
        while next_audio is not None and now >= next_audio:
            next_audio += 0.01
            audio_sequence += 1
            packet = audio_packet(audio_sequence, audio_sequence * 480)
            if audio_sequence % 50 == 0:
                continue  # 잃은 패킷
            if audio_sequence == 120:
                held_audio = packet  # 다음 것 뒤에 보낸다 (순서 바뀜)
                continue
            send(packet, asker)
            audio_packets += 1
            if held_audio is not None:
                send(held_audio, asker)
                held_audio = None
                audio_packets += 1

        # 몸만 보내는 VMC 앱 (P13): 허락 송신기가 Ack를 받은 1~9초, 30Hz
        if asker_ack is not None and next_body_frame is None:
            next_body_frame = asker_ack + 1
        if next_body_frame is not None and now >= next_body_frame and now - asker_ack < 9:
            next_body_frame += 1 / 30
            body_frames += 1
            for bundle in osc_bundles(body_messages(elapsed, full=True) + [osc_message("/VMC/Ext/OK", 1)]):
                send(bundle, body_only)

        sending = stopped_at is None
        if sending and now >= next_hello:
            next_hello += 1
            send(osc_message("/FaceLink/Hello", "1", "CI 송신기", "ci", session, token))

        if sending and now >= next_frame:
            next_frame += 1 / FPS
            sequence += 1
            tracking = not (since_ack is not None and 6 <= since_ack < 8)
            for bundle in osc_bundles(frame_messages(sequence, elapsed, tracking, elapsed)):
                send(bundle)
            frames += 1

        # t0+2초: 앱이 버려야 하는 것들 (한 번)
        if sending and not extras_sent and since_ack is not None and since_ack >= 2:
            extras_sent = True
            for _ in range(3):
                send(bytes(random.getrandbits(8) for _ in range(random.randint(1, 200))))
            send(b"/bad\0\0\0\0,q\0\0")  # 모르는 타입 태그
            send(osc_message("/VMC/Ext/Blend/Val", "JawOpen", 1.0)[:-3])  # 잘린 메시지
            # 지난 순번 프레임: 버려져야 하므로 값이 튀지 않는다
            for bundle in osc_bundles(frame_messages(max(1, sequence - 30), elapsed, True, elapsed + 100)):
                send(bundle)
            # 다른 주소: 틀린 페어링 코드의 Hello와 코드 없는 VMC
            send(osc_message("/FaceLink/Hello", "1", "틀린 송신기", "ci", str(uuid.uuid4()), "wrong-code"), rogue)
            for _ in range(5):
                send(osc_message("/VMC/Ext/Blend/Val", "JawOpen", 1.0), rogue)
                send(osc_message("/VMC/Ext/Blend/Apply"), rogue)
            log("facelink sender: sent garbage, a stale frame and a rogue sender")
            next_asker_hello = next_asker_frame = now

        # 코드 없는 송신기: 1초마다 Hello, 30Hz 프레임 (허락받기 전에는 앱이 버린다)
        if next_asker_hello is not None and now >= next_asker_hello:
            next_asker_hello += 1
            send(osc_message("/FaceLink/Hello", "1", "CI 허락 송신기", "ci", asker_session, ""), asker)
        if next_asker_frame is not None and now >= next_asker_frame:
            next_asker_frame += 1 / 30
            asker_sequence += 1
            for bundle in osc_bundles(frame_messages(asker_sequence, elapsed, True, elapsed)):
                send(bundle, asker)

        deadline = min(next_frame if sending else now + 0.05, next_hello if sending else now + 0.05,
                       next_asker_frame if next_asker_frame is not None else now + 0.05,
                       next_asker_hello if next_asker_hello is not None else now + 0.05)
        readable, _, _ = select.select([sock, asker], [], [], max(0.0, deadline - time.monotonic()))
        if asker in readable:
            data, _ = asker.recvfrom(65536)
            if data.startswith(osc_string("/FaceLink/Ack")) and asker_ack is None:
                asker_ack = time.monotonic()
                after = f"{asker_ack - stopped_at:.1f} s after" if stopped_at is not None else "before"
                log(f"facelink sender: allowed sender got an ack {after} the first sender stopped")
        if sock in readable:
            data, _ = sock.recvfrom(65536)
            try:
                address, args = parse_message(data)
            except (ValueError, struct.error, UnicodeDecodeError):
                failures.append(f"unreadable reply {data[:32]!r}")
                continue
            if address == "/FaceLink/Ack":
                acks += 1
                last_ack_time = time.monotonic()
                if first_ack is None:
                    first_ack = last_ack_time
                    log(f"facelink sender: first ack after {first_ack - started:.1f} s {args}")
                if len(args) != 3 or not isinstance(args[2], str):
                    failures.append(f"bad ack {args}")
            elif address == "/FaceLink/Calibrate":
                calibrated = True
                log("facelink sender: calibrate received")

    if stopped_at is not None and last_ack_time is not None and last_ack_time - stopped_at > 4:
        failures.append(f"acks did not stop ({last_ack_time - stopped_at:.1f} s after the sender stopped)")
    if max_datagram > MAX_DATAGRAM:
        failures.append(f"datagram {max_datagram} bytes > {MAX_DATAGRAM}")
    if first_ack is not None and not calibrated:
        failures.append("no calibrate from the app")
    if first_ack is not None and asker_ack is None:
        failures.append("the sender without a pairing code got no ack after it was allowed")
    if asker_ack is not None and (stopped_at is None or asker_ack < stopped_at):
        failures.append("the sender without a pairing code got an ack while the paired sender was active")
    log(f"facelink sender: sent {frames} frames (max datagram {max_datagram} bytes), acks {acks}, "
        f"calibrate {'yes' if calibrated else 'no'}, body-only frames {body_frames}, audio packets {audio_packets}")
    if first_ack is not None and asker_ack is not None and body_frames == 0:
        failures.append("the body-only sender did not send")
    for failure in failures:
        log(f"FAIL {failure}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
