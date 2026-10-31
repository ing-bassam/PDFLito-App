#!/usr/bin/env python3
"""Draws the 1024x1024 app icon (RGB, no transparency) without third-party libraries.

Usage: python3 scripts/make_icon.py PDFLito/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import math
import struct
import sys
import zlib

SIZE = 1024


def clamp(value, low=0.0, high=1.0):
    return low if value < low else high if value > high else value


def rounded_rect(px, py, cx, cy, half_w, half_h, radius):
    qx = abs(px - cx) - half_w + radius
    qy = abs(py - cy) - half_h + radius
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - radius


def segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = clamp(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def mix(pixel, color, alpha):
    if alpha <= 0:
        return pixel
    return tuple(p * (1 - alpha) + c * alpha for p, c in zip(pixel, color))


def coverage(distance):
    return clamp(0.5 - distance)


# Geometry
DOC_CX, DOC_CY, DOC_HW, DOC_HH, DOC_R = 500, 500, 250, 330, 44
FOLD = 130
DOC_RIGHT, DOC_TOP = DOC_CX + DOC_HW, DOC_CY - DOC_HH
CUT = (DOC_RIGHT - FOLD) - DOC_TOP  # points with x - y > CUT lie beyond the fold line
BADGE_X, BADGE_Y, BADGE_R = 742, 790, 150

TOP_LEFT = (29, 96, 214)
BOTTOM_RIGHT = (16, 178, 196)
WHITE = (255, 255, 255)
FOLD_COLOR = (205, 222, 240)
HEADING = (29, 96, 214)
TEXT_LINE = (196, 205, 218)
SHADOW = (8, 40, 90)
BADGE = (38, 186, 104)

LINES = [  # (x0, x1, y, half thickness)
    (330, 560, 330, 26),  # heading
    (330, 650, 430, 11),
    (330, 610, 480, 11),
    (330, 640, 530, 11),
    (330, 520, 580, 11),
    (330, 600, 650, 11),
    (330, 470, 700, 11),
]


def document_distance(x, y):
    body = rounded_rect(x, y, DOC_CX, DOC_CY, DOC_HW, DOC_HH, DOC_R)
    beyond_fold = ((x - y) - CUT) / math.sqrt(2)
    return max(body, beyond_fold)


def fold_distance(x, y):
    left = (DOC_RIGHT - FOLD) - x
    bottom = y - (DOC_TOP + FOLD)
    diagonal = ((x - y) - CUT) / math.sqrt(2)
    return max(left, bottom, diagonal)


def shade(x, y):
    t = clamp((x + y) / (2 * SIZE))
    pixel = tuple(a + (b - a) * t for a, b in zip(TOP_LEFT, BOTTOM_RIGHT))

    if 180 < x < 820 and 140 < y < 900:
        shadow = document_distance(x, y - 22)
        pixel = mix(pixel, SHADOW, 0.28 * clamp((40 - shadow) / 60))
        pixel = mix(pixel, WHITE, coverage(document_distance(x, y)))
        pixel = mix(pixel, FOLD_COLOR, coverage(fold_distance(x, y)))
        for x0, x1, ly, half in LINES:
            if abs(y - ly) <= half + 2 and x0 - half - 2 <= x <= x1 + half + 2:
                color = HEADING if half > 20 else TEXT_LINE
                pixel = mix(pixel, color, coverage(segment(x, y, x0, ly, x1, ly) - half))

    if abs(x - BADGE_X) <= BADGE_R + 30 and abs(y - BADGE_Y) <= BADGE_R + 30:
        ring = math.hypot(x - BADGE_X, y - BADGE_Y)
        pixel = mix(pixel, SHADOW, 0.25 * clamp((BADGE_R + 26 - ring) / 30))
        pixel = mix(pixel, WHITE, coverage(ring - (BADGE_R + 14)))
        pixel = mix(pixel, BADGE, coverage(ring - BADGE_R))
        check = min(segment(x, y, 672, 795, 722, 848), segment(x, y, 722, 848, 818, 735))
        pixel = mix(pixel, WHITE, coverage(check - 24))
    return pixel


def write_png(path, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", header))
        handle.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        handle.write(chunk(b"IEND", b""))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rows = []
    for y in range(SIZE):
        row = bytearray()
        for x in range(SIZE):
            r, g, b = shade(x + 0.5, y + 0.5)
            row += bytes((int(round(r)), int(round(g)), int(round(b))))
        rows.append(row)
    write_png(sys.argv[1], rows)


if __name__ == "__main__":
    main()
