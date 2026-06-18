#!/usr/bin/env bash
#
# sync-to-drive.sh — copy the make-video runtime to a drive folder for
# zero-install handoff (the friend's Apple Silicon Mac, no install).
#
# Usage: ./sync-to-drive.sh [DEST]
#   DEST defaults to "/Volumes/1TB SSD/ImageToVideo".
#
# Copies make-video + lib/ + README.txt. Leaves bin/ffmpeg/ffprobe in place
# if already on the drive; otherwise copies the local bundled binaries, or
# tells you to run setup-mac-arm64.sh first.

set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-/Volumes/1TB SSD/ImageToVideo}"
drive_root="$(dirname "$dest")"

[[ -d "$drive_root" ]] || { echo "error: '$drive_root' not found — is the drive mounted?" >&2; exit 1; }

mkdir -p "$dest/lib" "$dest/bin"
cp "$src/make-video" "$src/README.txt" "$dest/"
cp "$src/lib/"*.sh "$dest/lib/"
chmod +x "$dest/make-video" 2>/dev/null || true   # exFAT may ignore; bash runs it regardless

if [[ -f "$dest/bin/ffmpeg" && -f "$dest/bin/ffprobe" ]]; then
  echo "bin/: ffmpeg + ffprobe already on drive (kept)."
elif [[ -f "$src/bin/ffmpeg" && -f "$src/bin/ffprobe" ]]; then
  cp "$src/bin/ffmpeg" "$src/bin/ffprobe" "$dest/bin/"
  echo "bin/: copied bundled ffmpeg + ffprobe to drive."
else
  echo "NOTE: no ffmpeg in '$dest/bin' and none local — run ./setup-mac-arm64.sh first." >&2
fi

echo "synced make-video + lib/ (${dest})"
