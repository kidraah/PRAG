#!/bin/bash
# Builds the sample files the demo scenes expect, from wallpapers that ship with macOS.
#   scripts/readme-media/make-samples.sh <out-dir>
set -euo pipefail
OUT=$1; WP="/System/Library/Desktop Pictures"
mkdir -p "$OUT"; cd "$OUT"
sips -s format jpeg -s formatOptions 95 "$WP/Sonoma.heic" --out "Sunset Ridge.jpg" >/dev/null
sips -s format png -Z 2600 "$WP/Mac Purple.heic" --out "Brand Mockup.png" >/dev/null
cp "$WP/Radial Sky Blue.heic" "IMG_4821.HEIC"
sips -s format jpeg -Z 2200 "$WP/iMac Silver.heic" --out deck.jpg >/dev/null && sips -s format pdf deck.jpg --out "Pitch Deck.pdf" >/dev/null && rm deck.jpg
sips -s format jpeg -Z 2200 "$WP/Mac Blue.heic" --out c.jpg >/dev/null && sips -s format pdf c.jpg --out "Contract Draft.pdf" >/dev/null && rm c.jpg
sips -s format jpeg -s formatOptions 70 -Z 2560 "$WP/Sonoma.heic" --out wallpaper.jpg >/dev/null
echo "samples in $OUT"
