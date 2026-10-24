"""임시 앱 아이콘 (2026-10-24, TestFlight 업로드에 아이콘이 필요해서): 남색 바탕, 빨간 "방송 중" 점, 흰 전파 호.
App Store Connect가 받는 1024x1024 불투명 PNG를 만든다. 모서리는 iPadOS가 둥글게 자른다.

사용법: python make-app-icon.py Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png  (Pillow 필요)
"""

import math
import sys

from PIL import Image, ImageDraw

out = sys.argv[1]
N = 4096  # 크게 그린 뒤 줄여 가장자리를 매끈하게
img = Image.new("RGB", (N, N))
px = img.load()
# 남색 세로 그라데이션 (위가 조금 밝게)
top, bottom = (28, 46, 92), (10, 16, 38)
draw = ImageDraw.Draw(img)
for y in range(N):
    t = y / (N - 1)
    color = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
    draw.line([(0, y), (N, y)], fill=color)

cx, cy = N / 2, N / 2
white = (245, 247, 252)
red = (238, 52, 64)

# 가운데 빨간 점 (방송 중)
r = N * 0.11
draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=red)

# 양쪽 전파 호 두 겹
width = round(N * 0.045)
for radius in (N * 0.21, N * 0.31):
    box = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(box, start=-40, end=40, fill=white, width=width)
    draw.arc(box, start=140, end=220, fill=white, width=width)
# 호 끝을 둥글게
for radius in (N * 0.21, N * 0.31):
    for angle in (-40, 40, 140, 220):
        a = math.radians(angle)
        mid = radius - width / 2
        x, y = cx + mid * math.cos(a), cy + mid * math.sin(a)
        draw.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=white)

icon = img.resize((1024, 1024), Image.LANCZOS)
icon.save(out, "PNG", optimize=True)
print("saved", out, icon.size, icon.mode)
