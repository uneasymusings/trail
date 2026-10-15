#!/usr/bin/env bash
# Installs the latest Trail release into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/uneasymusings/trail/main/scripts/install.sh | bash
set -euo pipefail
repo="uneasymusings/trail"

if [[ "$(uname -s)" != "Darwin" ]]; then echo "Trail runs on macOS only."; exit 1; fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 26 )); then echo "Trail needs macOS 26 or later."; exit 1; fi
if [[ "$(uname -m)" != "arm64" ]]; then echo "Trail needs an Apple silicon Mac."; exit 1; fi

url="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
if [[ -z "$url" ]]; then echo "No release found at github.com/$repo/releases."; exit 1; fi

work="$(mktemp -d)"
trap 'hdiutil detach "$work/mnt" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT
echo "Downloading $url"
curl -fsSL "$url" -o "$work/Trail.dmg"
hdiutil attach "$work/Trail.dmg" -mountpoint "$work/mnt" -nobrowse -quiet
pkill -x Trail 2>/dev/null || true
rm -rf /Applications/Trail.app
cp -R "$work/mnt/Trail.app" /Applications/
open /Applications/Trail.app
echo "Trail is installed. Press ⌥Space to search."
