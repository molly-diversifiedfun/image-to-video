#!/usr/bin/env bash
#
# tests/helpers/fixtures.sh — generate tiny ffmpeg media into a temp dir.
#
# Usage: source this file from a bats test via:
#   load "$REPO_ROOT/tests/helpers/fixtures.sh"
#
# After sourcing, $FFMPEG and $FFPROBE are set, and the generator functions
# below are available.

# ---------------------------------------------------------------------------
# Locate ffmpeg / ffprobe
# Mirror the same logic used in the main `make-video` script:
#   1. Prefer repo-local bin/ next to the test helpers (two levels up = repo root)
#   2. Fall back to whatever is on PATH
# ---------------------------------------------------------------------------
_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_FIXTURES_DIR/../.." && pwd)"

if [[ -f "$_REPO_ROOT/bin/ffmpeg" && -f "$_REPO_ROOT/bin/ffprobe" ]]; then
  chmod +x "$_REPO_ROOT/bin/ffmpeg" "$_REPO_ROOT/bin/ffprobe" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$_REPO_ROOT/bin" 2>/dev/null || true
  FFMPEG="$_REPO_ROOT/bin/ffmpeg"
  FFPROBE="$_REPO_ROOT/bin/ffprobe"
else
  FFMPEG="$(command -v ffmpeg || true)"
  FFPROBE="$(command -v ffprobe || true)"
fi

[[ -n "$FFMPEG" ]] || { echo "fixtures.sh: ffmpeg not found" >&2; return 1; }
[[ -n "$FFPROBE" ]] || { echo "fixtures.sh: ffprobe not found" >&2; return 1; }

export FFMPEG FFPROBE

# ---------------------------------------------------------------------------
# mk_image OUT COLOR
#
# Generate a single still image (320x180 solid color, PNG).
#   OUT   — output file path (must end in a recognisable image extension)
#   COLOR — any color name or hex that ffmpeg's color filter accepts, e.g. red, #3399ff
# ---------------------------------------------------------------------------
mk_image() {
  local out="${1:?mk_image: OUT required}"
  local color="${2:-blue}"

  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "color=c=${color}:s=320x180:d=1" \
    -frames:v 1 \
    "$out"
}

# ---------------------------------------------------------------------------
# mk_clip OUT [FREQ] [SECS]
#
# Generate a small clip WITH both audio and video:
#   - video: gradients lavfi source (smooth low-motion, 320x180, 30 fps)
#   - audio: sine wave at FREQ Hz
#   - codecs: libx264/yuv420p + aac
#   OUT  — output file path (.mp4)
#   FREQ — sine frequency in Hz (default 220)
#   SECS — duration in seconds  (default 3)
# ---------------------------------------------------------------------------
mk_clip() {
  local out="${1:?mk_clip: OUT required}"
  local freq="${2:-220}"
  local secs="${3:-3}"

  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "gradients=s=320x180:speed=0.01,format=yuv420p" \
    -f lavfi -i "sine=frequency=${freq}:sample_rate=44100" \
    -t "$secs" \
    -c:v libx264 -preset ultrafast -crf 23 \
    -c:a aac -b:a 64k \
    -pix_fmt yuv420p \
    -r 30 \
    "$out"
}

# ---------------------------------------------------------------------------
# mk_audio OUT FREQ SECS
#
# Generate a pure AAC audio-only file (no video stream) from a sine wave.
#   OUT  — output file path (.aac or .m4a)
#   FREQ — frequency in Hz
#   SECS — duration in seconds
# ---------------------------------------------------------------------------
mk_audio() {
  local out="${1:?mk_audio: OUT required}"
  local freq="${2:?mk_audio: FREQ required}"
  local secs="${3:?mk_audio: SECS required}"

  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "sine=frequency=${freq}:sample_rate=44100" \
    -t "$secs" \
    -c:a aac -b:a 64k \
    "$out"
}
