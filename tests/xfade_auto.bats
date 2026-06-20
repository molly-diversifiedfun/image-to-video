#!/usr/bin/env bats
#
# xfade_auto.bats — tests for lib/xfade_auto.sh :: detect_audio_xfade
#
# Contract: pick an AUDIO crossfade length from how different a clip's start and
# end ambience are RELATIVE to the clip's natural drift.
#   - stationary ambience      → short (near the MIN)
#   - drifting ambience        → notably longer than stationary
#   - silent / no audio        → MIN (nothing to blend)
#   - result always clamped to [MIN, duration × MAXFRAC]

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
bats_require_minimum_version 1.5.0

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  source "$REPO_ROOT/lib/xfade_auto.sh"
  WORK_DIR="$(mktemp -d)"
}
teardown() { rm -rf "$WORK_DIR"; }

# ---------------------------------------------------------------------------
# Test 1 — stationary ambience picks a SHORT crossfade (near the min).
# ---------------------------------------------------------------------------
@test "detect_audio_xfade: stationary ambience → short crossfade" {
  local clip="$WORK_DIR/stationary.mp4"
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "anoisesrc=d=30:c=pink:a=0.3" \
    -c:a aac "$clip"

  local x
  x="$(detect_audio_xfade "$clip" 3)"
  echo "stationary → ${x}s"
  # Should be modest — well under a quarter of the clip.
  awk -v v="$x" 'BEGIN{ exit !(v >= 3 && v <= 6) }'
}

# ---------------------------------------------------------------------------
# Test 2 — drifting ambience picks a LONGER crossfade than stationary (TEETH).
#
# Head is a low rumble, tail is a bright hiss → a large endpoint gap → the
# detector must stretch the crossfade well past the stationary case.
# ---------------------------------------------------------------------------
@test "detect_audio_xfade: drifting ambience → longer than stationary" {
  local stat="$WORK_DIR/stat.mp4" drift="$WORK_DIR/drift.mp4"
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "anoisesrc=d=30:c=pink:a=0.3" -c:a aac "$stat"

  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "anoisesrc=d=15:c=pink:a=0.5,lowpass=f=250" "$WORK_DIR/r.wav"
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "anoisesrc=d=15:c=white:a=0.4,highpass=f=4000" "$WORK_DIR/h.wav"
  printf "file '%s/r.wav'\nfile '%s/h.wav'\n" "$WORK_DIR" "$WORK_DIR" > "$WORK_DIR/c.txt"
  "$FFMPEG" -nostdin -loglevel error -y -f concat -safe 0 -i "$WORK_DIR/c.txt" -c:a aac "$drift"

  local xs xd
  xs="$(detect_audio_xfade "$stat" 3)"
  xd="$(detect_audio_xfade "$drift" 3)"
  echo "stationary=${xs}s  drifting=${xd}s"
  # Drift must demand a strictly (and clearly) longer crossfade.
  awk -v s="$xs" -v d="$xd" 'BEGIN{ exit !(d > s + 2) }'
}

# ---------------------------------------------------------------------------
# Test 3 — silent clip → MIN (nothing to blend).
# ---------------------------------------------------------------------------
@test "detect_audio_xfade: silent clip → min" {
  local clip="$WORK_DIR/silent.mp4"
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "anullsrc=r=44100:cl=stereo" -t 20 \
    -c:a aac "$clip"

  local x
  x="$(detect_audio_xfade "$clip" 3)"
  echo "silent → ${x}s"
  awk -v v="$x" 'BEGIN{ exit !(v == 3) }'
}

# ---------------------------------------------------------------------------
# Test 4 — clip with NO audio stream → MIN, no error.
# ---------------------------------------------------------------------------
@test "detect_audio_xfade: no audio stream → min, no error" {
  local clip="$WORK_DIR/noaudio.mp4"
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "gradients=s=160x90:speed=0.01,format=yuv420p" \
    -t 12 -c:v libx264 -preset ultrafast -an -r 30 "$clip"

  run detect_audio_xfade "$clip" 3
  [ "$status" -eq 0 ]
  echo "no-audio → $output"
  [ "$output" = "3" ] || [ "$output" = "3.0" ]
}

# ---------------------------------------------------------------------------
# Test 5 — result is clamped to clip × MAXFRAC (a heavy-drift short clip can't
# ask for a crossfade longer than a third of itself).
# ---------------------------------------------------------------------------
@test "detect_audio_xfade: result clamped to duration fraction" {
  local drift="$WORK_DIR/drift.mp4"
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "anoisesrc=d=9:c=pink:a=0.5,lowpass=f=200" "$WORK_DIR/r.wav"
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "anoisesrc=d=9:c=white:a=0.5,highpass=f=5000" "$WORK_DIR/h.wav"
  printf "file '%s/r.wav'\nfile '%s/h.wav'\n" "$WORK_DIR" "$WORK_DIR" > "$WORK_DIR/c.txt"
  "$FFMPEG" -nostdin -loglevel error -y -f concat -safe 0 -i "$WORK_DIR/c.txt" -c:a aac "$drift"

  # 18s clip, maxfrac 0.3333 → cap = 6s.
  local x
  x="$(detect_audio_xfade "$drift" 3 0.3333)"
  echo "heavy-drift 18s clip → ${x}s (cap 6s)"
  awk -v v="$x" 'BEGIN{ exit !(v <= 6.01) }'
}
