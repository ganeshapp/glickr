#!/usr/bin/env bash
# Rasterize brand/*.svg into the PNG masters that flutter_launcher_icons and
# the app itself consume. Re-run after editing any SVG, then:
#   dart run flutter_launcher_icons
#
# rsvg-convert is the only SVG rasteriser installed on the dev machine
# (no ImageMagick, no Inkscape, no cairosvg). Install with:
#   brew install librsvg
set -euo pipefail

cd "$(dirname "$0")/.."
SRC=brand
OUT=assets/brand
mkdir -p "$OUT"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found. brew install librsvg" >&2
  exit 1
fi

# -a keeps the aspect ratio; without it a non-square viewBox silently stretches.
# -b none preserves the alpha channel - never pass -b to a layer that must be
# transparent, it collapses the output to opaque RGB.
rsvg-convert -w 1024 -h 1024 -a         "$SRC/glickr_icon.svg"       -o "$OUT/glickr_icon_1024.png"
rsvg-convert -w 1024 -h 1024 -a -b none "$SRC/glickr_foreground.svg" -o "$OUT/glickr_foreground_1024.png"
rsvg-convert -w 1024 -h 1024 -a -b none "$SRC/glickr_monochrome.svg" -o "$OUT/glickr_monochrome_1024.png"
rsvg-convert -w  512 -h  512 -a         "$SRC/glickr_icon.svg"       -o "$OUT/glickr_playstore_512.png"

# In-app mark, transparent, at the sizes the login hero and about screen use.
rsvg-convert -w 512 -h 512 -a -b none "$SRC/glickr_mark.svg" -o "$OUT/glickr_mark.png"

echo "Wrote:"
ls -la "$OUT"
