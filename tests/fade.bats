#!/usr/bin/env bats
#
# fade.bats — tests for lib/fade.sh :: apply_fades IN FADE OUT
#
# Contract:
#   - The first FADE seconds fade UP from black; the last FADE seconds fade
#     DOWN to black (video).  Audio fades in/out to match.
#   - Total duration is preserved (the fades replace existing frames, they do
#     not add length).
#   - The long middle is NOT black (only the two ends are).
#   - Split path (2×FADE < D) re-encodes only head+tail and copies the middle;
#     whole-file path (2×FADE >= D) does it in one pass.  Both produce a valid,
#     duration-preserving, black-ended output.
#   - A no-audio source yields a video-only faded output without error.
#
# Detection: ffmpeg's `blackframe` filter lists frames that are ~all black.
# A correct top-and-tail fade puts black frames at BOTH ends and none in the
# middle.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

bats_require_minimum_version 1.5.0

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  source "$REPO_ROOT/lib/fade.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

# Space-separated list of 0-based frame indices ffmpeg flags as ~all black.
_black_frames() {
  "$FFMPEG" -nostdin -i "$1" -vf "blackframe=amount=90:threshold=32" -an -f null - 2>&1 \
    | grep -oE 'frame:[0-9]+' | cut -d: -f2 | tr '\n' ' '
}

_frame_count() {
  "$FFPROBE" -v error -select_streams v:0 -count_packets \
    -show_entries stream=nb_read_packets -of default=noprint_wrappers=1:nokey=1 "$1"
}

# ---------------------------------------------------------------------------
# Test 1 — split path (long file): ends fade to/from black, middle stays bright,
# duration preserved, audio retained.
# ---------------------------------------------------------------------------
@test "apply_fades (split path): black at both ends, bright middle, duration + audio preserved" {
  local clip="$WORK_DIR/clip.mp4"
  local out="$WORK_DIR/faded.mp4"
  mk_clip "$clip" 220 12        # 12s; 2×fade(2)=4 < 12 → split path

  run apply_fades "$clip" 2 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  # Duration preserved (±0.5s)
  assert_duration "$out" 12 0.5
  # Audio survived
  assert_has_stream "$out" a

  local n black
  n="$(_frame_count "$out")"
  black=" $(_black_frames "$out") "
  echo "frames=$n black=$black"

  # First and last frames must be black (faded to/from black)
  [[ "$black" == *" 0 "* ]]
  [[ "$black" == *" $((n-1)) "* ]]
  # A middle frame must NOT be black (only the ends fade)
  [[ "$black" != *" $((n/2)) "* ]]
}

# ---------------------------------------------------------------------------
# Test 2 — whole-file path (fade window >= half the clip): still valid + black
# ends + duration preserved.  Exercises the single-pass branch.
# ---------------------------------------------------------------------------
@test "apply_fades (whole-file path): short clip still fades cleanly" {
  local clip="$WORK_DIR/clip.mp4"
  local out="$WORK_DIR/faded.mp4"
  mk_clip "$clip" 220 3         # 3s; fade 2 → 2×2=4 >= 3 → whole-file path

  run apply_fades "$clip" 2 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  assert_duration "$out" 3 0.5

  local n black
  n="$(_frame_count "$out")"
  black=" $(_black_frames "$out") "
  echo "frames=$n black=$black"
  [[ "$black" == *" 0 "* ]]
  [[ "$black" == *" $((n-1)) "* ]]
}

# ---------------------------------------------------------------------------
# Test 3 — no-audio source: produces a video-only faded output without error.
# ---------------------------------------------------------------------------
@test "apply_fades: no-audio clip → video-only faded output, no error" {
  local silent="$WORK_DIR/silent.mp4"
  local out="$WORK_DIR/faded.mp4"
  # 12s silent (no audio stream)
  "$FFMPEG" -nostdin -loglevel error -y \
    -f lavfi -i "gradients=s=320x180:speed=0.01,format=yuv420p" \
    -t 12 -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p -r 30 -an "$silent"

  run apply_fades "$silent" 2 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  assert_has_stream "$out" v
  # No audio stream should have been invented
  run assert_has_stream "$out" a
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Test 4 — integration: make-video loop-extend + --fade tops-and-tails the
# final long file (black ends), end to end.
# ---------------------------------------------------------------------------
@test "make-video loop-extend --fade 2: final output fades to/from black" {
  local clip="$WORK_DIR/rain.mp4"
  local out="$WORK_DIR/sleep.mp4"
  mk_clip "$clip" 220 4

  run "$REPO_ROOT/make-video" "$clip" 0.0056 --yes --fade 2 --out "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  assert_has_stream "$out" v

  local n black
  n="$(_frame_count "$out")"
  black=" $(_black_frames "$out") "
  echo "frames=$n black=$black"
  [[ "$black" == *" 0 "* ]]
  [[ "$black" == *" $((n-1)) "* ]]
  [[ "$black" != *" $((n/2)) "* ]]
}

# ---------------------------------------------------------------------------
# Test 5 — invalid --fade value is rejected with a clear error.
# ---------------------------------------------------------------------------
@test "make-video --fade abc: rejected with a clear error" {
  local clip="$WORK_DIR/rain.mp4"
  mk_clip "$clip" 220 4

  run "$REPO_ROOT/make-video" "$clip" 0.0056 --yes --fade abc --out "$WORK_DIR/o.mp4"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE "fade"
}
