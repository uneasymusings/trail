#!/usr/bin/env bash
# Records the README GIFs against a made-up home folder, so no real files ever appear.
#   scripts/demo/record.sh            # all scenes
#   scripts/demo/record.sh search     # one scene
# Needs: Xcode build of the app, ffmpeg, and Screen Recording permission for your terminal.
# Your keyboard stays yours while it records: the panel never takes focus.
set -euo pipefail
cd "$(dirname "$0")/../.."

APP="build/Build/Products/Release/Trail.app"
DEMO="$PWD/.demo"
OUT="docs/media"
if [[ $# -gt 0 ]]; then scenes=("$@"); else scenes=(search ask first-run); fi
length() { case "$1" in search) echo 20 ;; ask) echo 22 ;; *) echo 13 ;; esac; }
stage() { case "$1" in first-run) echo "380 140" ;; *) echo "900 620" ;; esac; }

command -v ffmpeg >/dev/null || { echo "Needs ffmpeg (brew install ffmpeg)."; exit 1; }
[[ -d "$APP" ]] || make app
swift build -c release >/dev/null
mkdir -p "$DEMO" && swiftc -O scripts/demo/capture.swift -o "$DEMO/capture"

echo "Building the demo home…"
swift scripts/demo/make-home.swift "$DEMO/home" >/dev/null
rm -rf "$DEMO/index"
export TRAIL_HOME="$DEMO/index" TRAIL_USER_HOME="$DEMO/home"
.build/release/trail scan >/dev/null
.build/release/trail enrich >/dev/null 2>&1 || echo "  (no Apple Intelligence: recording without file notes)"

read -r sw sh < <(swift -e 'import AppKit; let f = NSScreen.screens[0].frame; print(Int(f.width), Int(f.height))' 2>/dev/null)
mkdir -p "$OUT"

for scene in "${scenes[@]}"; do
  # Each scene gets a stage centered near the top of the main display.
  read -r w h < <(stage "$scene")
  x=$(( (sw - w) / 2 )) y=$(( (sh - h) / 3 ))
  echo "Recording ${scene}…"
  TRAIL_DEMO="$PWD/scripts/demo/scenes/$scene.json" TRAIL_DEMO_STAGE="$x,$y,$w,$h" \
    "$APP/Contents/MacOS/Trail" >/dev/null 2>&1 &
  pid=$!
  sleep 1.2                                   # let the stage cover the area first
  "$DEMO/capture" "$x" "$y" "$w" "$h" "$(length "$scene")" "$DEMO/$scene.mov"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # The first seconds cover ScreenCaptureKit warming up (scenes start late on purpose); trim them.
  # It also stops sending frames once the screen is still, so hold the last frame a moment.
  ffmpeg -loglevel error -y -ss 3.6 -i "$DEMO/$scene.mov" -vf \
    "tpad=stop_mode=clone:stop_duration=2.5,fps=15,scale=$(( w * 68 / 90 )):-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff:max_colors=160[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    "$OUT/$scene.gif"
  echo "  → $OUT/$scene.gif ($(du -h "$OUT/$scene.gif" | cut -f1))"
done
