#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["Pillow"]
# ///
"""Align Tauri Explorer background color to match a reference app (Ghostty).

Tauri Explorer applies internal compositing that shifts theme colors.
This script samples pixel colors from a screenshot of both apps side by side,
calculates the offset, and outputs a compensated hex value.

Usage:
    uv run scripts/align_colors.py <screenshot> <theme_hex> \
        --ref-region x1,y1,x2,y2 --target-region x1,y1,x2,y2

    uv run scripts/align_colors.py <screenshot> <theme_hex> \
        --auto

Args:
    screenshot: Path to a screenshot showing both apps side by side
    theme_hex:  Current Tauri Explorer background-solid hex value (e.g. #e4d3bc)
    --ref-region: Pixel region for reference app (Ghostty) as x1,y1,x2,y2
    --target-region: Pixel region for target app (Tauri Explorer) as x1,y1,x2,y2
    --auto: Automatically sample from left half (reference) and right half (target)
"""

import argparse
import sys
from PIL import Image


def hex_to_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def rgb_to_hex(r: int, g: int, b: int) -> str:
    return f"#{r:02x}{g:02x}{b:02x}"


def avg_color(img: Image.Image, x1: int, y1: int, x2: int, y2: int) -> tuple[int, int, int]:
    pixels = []
    for x in range(x1, x2):
        for y in range(y1, y2):
            pixels.append(img.getpixel((x, y))[:3])
    r = sum(p[0] for p in pixels) // len(pixels)
    g = sum(p[1] for p in pixels) // len(pixels)
    b = sum(p[2] for p in pixels) // len(pixels)
    return r, g, b


def parse_region(s: str) -> tuple[int, int, int, int]:
    parts = [int(x) for x in s.split(",")]
    if len(parts) != 4:
        raise ValueError(f"Region must be x1,y1,x2,y2, got: {s}")
    return tuple(parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("screenshot", help="Path to screenshot")
    parser.add_argument("theme_hex", help="Current theme background hex (e.g. #e4d3bc)")
    parser.add_argument("--ref-region", help="Reference region x1,y1,x2,y2")
    parser.add_argument("--target-region", help="Target region x1,y1,x2,y2")
    parser.add_argument("--auto", action="store_true", help="Auto-detect regions")
    args = parser.parse_args()

    img = Image.open(args.screenshot)
    w, h = img.size
    print(f"Image size: {w}x{h}")

    if args.auto:
        # Reference (Ghostty): top-left quadrant background
        ref_region = (5, 5, w // 4, h // 4)
        # Target (Tauri Explorer): bottom-right quadrant background
        target_region = (w // 2 + 50, h - h // 4, w - 10, h - 10)
    elif args.ref_region and args.target_region:
        ref_region = parse_region(args.ref_region)
        target_region = parse_region(args.target_region)
    else:
        print("Error: provide --auto or both --ref-region and --target-region", file=sys.stderr)
        sys.exit(1)

    ref_r, ref_g, ref_b = avg_color(img, *ref_region)
    tgt_r, tgt_g, tgt_b = avg_color(img, *target_region)
    cur_r, cur_g, cur_b = hex_to_rgb(args.theme_hex)

    print(f"Reference (Ghostty) rendered: rgb({ref_r}, {ref_g}, {ref_b}) = {rgb_to_hex(ref_r, ref_g, ref_b)}")
    print(f"Target (Tauri) rendered:      rgb({tgt_r}, {tgt_g}, {tgt_b}) = {rgb_to_hex(tgt_r, tgt_g, tgt_b)}")
    print(f"Current theme value:          {args.theme_hex}")
    print(f"Render offset (theme - rendered): R={cur_r - tgt_r:+d}, G={cur_g - tgt_g:+d}, B={cur_b - tgt_b:+d}")

    # Compensate: new_theme = reference_rendered + offset
    off_r = cur_r - tgt_r
    off_g = cur_g - tgt_g
    off_b = cur_b - tgt_b
    new_r = min(255, max(0, ref_r + off_r))
    new_g = min(255, max(0, ref_g + off_g))
    new_b = min(255, max(0, ref_b + off_b))

    compensated = rgb_to_hex(new_r, new_g, new_b)
    print(f"\nCompensated theme value:      {compensated}")
    print(f"  --background-solid: {compensated};")
    print(f"  --background-mica: {compensated};")
    print(f"  --content-bg: {compensated};")

    # Derive secondary shades
    card = rgb_to_hex(max(0, new_r - 12), max(0, new_g - 12), max(0, new_b - 10))
    card_sec = rgb_to_hex(max(0, new_r - 8), max(0, new_g - 8), max(0, new_b - 6))
    acrylic = rgb_to_hex(max(0, new_r - 5), max(0, new_g - 5), max(0, new_b - 4))
    print(f"  --background-acrylic: {acrylic};")
    print(f"  --background-card: {card};")
    print(f"  --background-card-secondary: {card_sec};")


if __name__ == "__main__":
    main()
