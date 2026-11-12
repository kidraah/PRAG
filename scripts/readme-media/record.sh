#!/bin/bash
# Records one scripted PRAG demo scene from the built-in (notched) display.
#   scripts/readme-media/record.sh <scene> <files-dir> <out-dir> [--light] [seconds]
# Scenes: park | act | sort | theme   (see Sources/PRAG/Demo/DemoDirector.swift)
# Needs Screen Recording permission for the terminal running it.
set -euo pipefail
SCENE=$1; FILES=$2; OUT=$3; EXTRA=${4:-}; SECS=${5:-24}
APP="$(cd "$(dirname "$0")/../.." && pwd)/build/PRAG.app/Contents/MacOS/PRAG"
mkdir -p "$OUT"
# Built-in display index for screencapture (-D). Main display is 1.
BUILTIN=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.screens; var r=1; for (var i=0;i<s.count;i++){ if (s.objectAtIndex(i).safeAreaInsets.top>0) r=i+1 }; r' 2>/dev/null || echo 1)
pkill -x PRAG 2>/dev/null || true
sleep 0.6
rm -f "$OUT/$SCENE.mov" "$OUT/$SCENE.json"
screencapture -v -D "$BUILTIN" -V "$SECS" -x "$OUT/$SCENE.mov" >/dev/null 2>&1 &
REC=$!
sleep 1.2
"$APP" --demo "$SCENE" --demo-files "$FILES" --demo-log "$OUT/$SCENE.json" $EXTRA >/dev/null 2>&1 &
wait $REC
pkill -x PRAG 2>/dev/null || true
echo "recorded $OUT/$SCENE.mov"
