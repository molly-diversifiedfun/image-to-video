#!/usr/bin/env bats
#
# smoke.bats — proves the test harness itself works:
#   - mk_clip generates a clip
#   - assert_duration passes for ~3s (tol 0.3)
#   - assert_has_stream detects both audio and video streams

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

@test "mk_clip produces a file" {
  mk_clip "$WORK_DIR/clip.mp4"
  [ -f "$WORK_DIR/clip.mp4" ]
}

@test "clip duration is approximately 3 seconds" {
  mk_clip "$WORK_DIR/clip.mp4"
  assert_duration "$WORK_DIR/clip.mp4" 3 0.3
}

@test "clip has a video stream" {
  mk_clip "$WORK_DIR/clip.mp4"
  assert_has_stream "$WORK_DIR/clip.mp4" v
}

@test "clip has an audio stream" {
  mk_clip "$WORK_DIR/clip.mp4"
  assert_has_stream "$WORK_DIR/clip.mp4" a
}

@test "mk_image produces a file" {
  mk_image "$WORK_DIR/frame.png" red
  [ -f "$WORK_DIR/frame.png" ]
}

@test "mk_audio produces a file" {
  mk_audio "$WORK_DIR/tone.aac" 440 2
  [ -f "$WORK_DIR/tone.aac" ]
}

@test "seam_ok passes on a clean mid-clip boundary" {
  # Use a longer clip (6s) so we have room for frame sampling
  mk_clip "$WORK_DIR/long.mp4" 220 6
  # Frame 90 is at the 3-second mark — interior, no seam
  assert_seam_ok "$WORK_DIR/long.mp4" 90
}

# --- Failure-path tests: the assertion must FAIL on bad inputs ---------------

@test "assert_has_stream FAILS on a video-only clip (no audio)" {
  # Build a silent video (no audio stream at all)
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x180:d=3,format=yuv420p" \
    -c:v libx264 -preset ultrafast \
    "$WORK_DIR/silent.mp4"
  # assert_has_stream for 'a' must return non-zero
  run assert_has_stream "$WORK_DIR/silent.mp4" a
  [ "$status" -ne 0 ]
}

@test "assert_seam_ok FAILS on a hard-cut between two solid colors" {
  # Two solid-color segments concatenated with a hard cut — boundary frames are
  # maximally different, so PSNR will be far below any baseline.
  local part1="$WORK_DIR/red.mp4"
  local part2="$WORK_DIR/green.mp4"
  local concat_list="$WORK_DIR/concat.txt"
  local seam_clip="$WORK_DIR/seam.mp4"

  "$FFMPEG" -nostdin -loglevel error -y \
    -f lavfi -i "color=c=red:s=320x180:d=2,format=yuv420p" \
    -c:v libx264 -preset ultrafast "$part1"
  "$FFMPEG" -nostdin -loglevel error -y \
    -f lavfi -i "color=c=green:s=320x180:d=2,format=yuv420p" \
    -c:v libx264 -preset ultrafast "$part2"

  printf "file '%s'\nfile '%s'\n" "$part1" "$part2" > "$concat_list"
  "$FFMPEG" -nostdin -loglevel error -y \
    -f concat -safe 0 -i "$concat_list" \
    -c copy "$seam_clip"

  # The concat sources encode at 25fps (default lavfi color fps).
  # 2s × 25fps = 50 frames per segment, so frame 50 is the first green frame.
  # assert_seam_ok checks frames (FRAME-1, FRAME) = (49, 50) = last red / first green.
  run assert_seam_ok "$seam_clip" 50
  [ "$status" -ne 0 ]
}
