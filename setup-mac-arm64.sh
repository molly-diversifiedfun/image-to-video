#!/usr/bin/env bash
#
# setup-mac-arm64.sh — fetch the bundled ffmpeg/ffprobe for Apple Silicon.
#
# Downloads static arm64 builds from osxexperts.net, verifies their SHA-256
# against the pinned values below, and installs them into ./bin so make-video
# runs with zero system dependencies.
#
# Re-pin the checksums here if you intentionally upgrade the FFmpeg version.

set -euo pipefail

readonly FFMPEG_URL="https://www.osxexperts.net/ffmpeg81arm.zip"
readonly FFPROBE_URL="https://www.osxexperts.net/ffprobe81arm.zip"
readonly FFMPEG_SHA="9a08d61f9328e8164ba560ee7a79958e357307fcfeea6fe626b7d66cdc287028"
readonly FFPROBE_SHA="aab17ac7379c1178aaf400c3ef36cdb67db0b75b1a23eeef2cb9f658be8844e6"

[[ "$(uname -m)" == "arm64" ]] || { echo "This installer is for Apple Silicon (arm64) Macs only." >&2; exit 1; }

dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$dir/bin"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

fetch() {  # url, zipname, dest, expected_sha
  echo "downloading $2 ..."
  curl -fsSL --max-time 180 -o "$tmp/$2" "$1"
  ( cd "$tmp" && unzip -o -q "$2" )
  local got; got="$(shasum -a 256 "$tmp/${3##*/}" | awk '{print $1}')"
  [[ "$got" == "$4" ]] || { echo "CHECKSUM MISMATCH for $3:\n  expected $4\n  got      $got" >&2; exit 1; }
  install -m 0755 "$tmp/${3##*/}" "$3"
  echo "  ok -> $3"
}

fetch "$FFMPEG_URL"  ffmpeg.zip  "$dir/bin/ffmpeg"  "$FFMPEG_SHA"
fetch "$FFPROBE_URL" ffprobe.zip "$dir/bin/ffprobe" "$FFPROBE_SHA"
echo "Done. make-video will now use ./bin/ffmpeg and ./bin/ffprobe."
