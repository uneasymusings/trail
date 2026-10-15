#!/usr/bin/env bash
# Packages Trail.app into a drag-to-Applications disk image.
# Usage: scripts/make-dmg.sh <path/to/Trail.app> <output.dmg>
set -euo pipefail
app="$1"
out="$2"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil create -volname "Trail" -srcfolder "$staging" -ov -format UDZO "$out" >/dev/null
echo "Created $out"
