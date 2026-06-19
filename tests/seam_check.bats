#!/usr/bin/env bats
#
# seam_check.bats — tests for lib/seam.sh :: seam_check VIDEO FRAME [--json]
#
# seam_check is a RUNTIME reporter used by the preview gate to tell an operator
# how visible a loop boundary is.  It measures PSNR at a boundary frame and
# compares it to a LOCAL baseline taken ~10 frames before.
#
# Verdict thresholds (drop = baseline_psnr - boundary_psnr):
#   drop <= 8 dB  → SEAMLESS (pingpong, or a seam-spanning crossfade loop)
#   8 < drop <= 18 dB → SOFT   (faint residual blend on sharp/high-motion content)
#   drop > 18 dB       → VISIBLE (hard cut / obvious jump)
#
# Return codes:
#   0 — successful measurement (regardless of verdict)
#   non-zero — measurement failure (missing file, bad frame, empty PSNR)
#
# Empirically observed on mk_clip (smooth gradient source, 30 fps):
#   pingpong wrap boundary    : drop ≈ 0–3 dB  → SEAMLESS
#   crossfade join boundary   : drop ≈ 1–2 dB  → SEAMLESS (seam-spanning dissolve,
#                               no backward content jump; was ~15–22 dB before the
#                               body-start-at-X fix)
#   hard-cut (solid color)    : drop ≈ 30–50 dB → VISIBLE
#
# NOTE: Test 3 asserts the crossfade seam is SEAMLESS — the fix's contract.
# Test 2 (hard cut → VISIBLE) keeps the teeth on seam_check's discrimination.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

bats_require_minimum_version 1.5.0

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  source "$REPO_ROOT/lib/loop.sh"
  source "$REPO_ROOT/lib/seam.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# Internal helper: concat FILE N times into OUT (stream-copy)
# ---------------------------------------------------------------------------
_sc_concat_n() {
  local file="$1"
  local n="$2"
  local out="$3"

  local list
  list="$(mktemp -p "$WORK_DIR" concat_list.XXXXXX)"
  mv "$list" "${list}.txt"
  list="${list}.txt"
  local i
  for (( i=0; i<n; i++ )); do
    echo "file '$file'" >> "$list"
  done

  local has_audio
  has_audio="$("$FFPROBE" -v error \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    "$file" | grep -c .)" || true
  has_audio="${has_audio:-0}"

  if [[ "$has_audio" -ge 1 ]]; then
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -f concat -safe 0 -i "$list" \
      -c copy \
      "$out"
  else
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -f concat -safe 0 -i "$list" \
      -c:v copy \
      -an \
      "$out"
  fi
}

# ---------------------------------------------------------------------------
# Internal helper: get frame count for a video file
# ---------------------------------------------------------------------------
_frame_count() {
  local file="$1"
  "$FFPROBE" -v error \
    -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file"
}

# ---------------------------------------------------------------------------
# Test 1: pingpong wrap boundary → SEAMLESS
#
# Build a 4s clip, create a pingpong loop unit (≈8s), concat-copy 2× (≈16s).
# The wrap boundary (frame = unit_frames in the tiled file) is TRULY seamless
# because the last frame of the reversed segment matches the first frame of
# the next forward pass.
# seam_check at that frame must report SEAMLESS.
# ---------------------------------------------------------------------------

@test "seam_check: pingpong wrap boundary reports SEAMLESS" {
  local clip="$WORK_DIR/clip.mp4"
  local unit="$WORK_DIR/unit_pp.mp4"
  local tiled="$WORK_DIR/tiled_pp.mp4"

  mk_clip "$clip" 220 4
  loop_unit "$clip" "$unit" --loop pingpong

  _sc_concat_n "$unit" 2 "$tiled"

  local unit_frames
  unit_frames="$(_frame_count "$unit")"

  run seam_check "$tiled" "$unit_frames"
  [ "$status" -eq 0 ]

  echo "output: $output"
  [[ "$output" == *"SEAMLESS"* ]]
}

# ---------------------------------------------------------------------------
# Test 2 (NEGATIVE CONTROL): hard-cut between two very different solid-color
# clips → verdict VISIBLE
#
# This test has TEETH.  If seam_check falsely reports SEAMLESS or SOFT for a
# hard cut, the thresholds are wrong and the test fails.
#
# Construction: concatenate a 3s pure-red clip and a 3s pure-blue clip with
# NO crossfade.  The PSNR at the cut frame (frame 90, 0-indexed = last frame
# of clip A / first frame of clip B) will be very low (near 0 dB) while the
# baseline ~10 frames before is near-infinite (identical solid-color frames).
# The drop will be >> 18 dB → must report VISIBLE.
# ---------------------------------------------------------------------------

@test "seam_check NEGATIVE CONTROL: hard cut between solid-color clips reports VISIBLE" {
  local red_clip="$WORK_DIR/red.mp4"
  local blue_clip="$WORK_DIR/blue.mp4"
  local hardcut="$WORK_DIR/hardcut.mp4"

  # Solid-color clips: no gradients, no motion — maximally different colors
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "color=c=red:s=320x180:d=3,format=yuv420p" \
    -r 30 \
    -c:v libx264 -preset ultrafast -crf 23 \
    -an \
    "$red_clip"

  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x180:d=3,format=yuv420p" \
    -r 30 \
    -c:v libx264 -preset ultrafast -crf 23 \
    -an \
    "$blue_clip"

  # Concatenate: red then blue, no transition
  local list
  list="$(mktemp -p "$WORK_DIR" hardcut.XXXXXX.txt)"
  echo "file '$red_clip'" > "$list"
  echo "file '$blue_clip'" >> "$list"
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f concat -safe 0 -i "$list" \
    -c:v copy -an \
    "$hardcut"

  # The cut frame: first frame of the blue segment (0-indexed frame 90 at 30fps)
  local cut_frame
  cut_frame="$(_frame_count "$red_clip")"

  run seam_check "$hardcut" "$cut_frame"
  [ "$status" -eq 0 ]

  echo "output: $output"
  # MUST be VISIBLE — a hard cut between solid red and solid blue cannot be SEAMLESS
  [[ "$output" == *"VISIBLE"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: crossfade join boundary → NOT VISIBLE (continuous seam, no jump)
#
# REGRESSION GUARD for the seam-spanning crossfade fix.  The loop unit is built
# so its first and last frames are the SAME source frame (CLIP@xfade): the real
# tail dissolves into the real head ACROSS the seam, with no backward content
# jump.  On the smooth-gradient fixture that makes the join continuous —
# seam_check must report SEAMLESS or SOFT, NEVER VISIBLE.
#
# (The earlier build dissolved into the head but then restarted the unit at
# content 0, leaving a 1 s backward jump that read as VISIBLE/large drop.  This
# test asserts that jump is gone.)  Test 2 (hard cut → VISIBLE) keeps the teeth
# on seam_check itself so this is not just rubber-stamping every input.
# ---------------------------------------------------------------------------

@test "seam_check: crossfade boundary is SEAMLESS (seam-spanning dissolve, no backward jump)" {
  local clip="$WORK_DIR/clip.mp4"
  local unit="$WORK_DIR/unit_xf.mp4"
  local tiled="$WORK_DIR/tiled_xf.mp4"

  # 4s clip satisfies 3× xfade = 3× 1s
  mk_clip "$clip" 220 4
  loop_unit "$clip" "$unit" --loop crossfade --xfade 1.0

  _sc_concat_n "$unit" 2 "$tiled"

  local unit_frames
  unit_frames="$(_frame_count "$unit")"

  run seam_check "$tiled" "$unit_frames"
  [ "$status" -eq 0 ]

  echo "output: $output"
  # TEETH: the OLD construction restarted the unit at content 0 after dissolving
  # into the head, leaving a 1 s backward jump → SOFT/VISIBLE here.  The fix
  # starts the body at content X so the seam joins content-X to content-X with
  # the dissolve straddling it → drop collapses to ~1 dB → SEAMLESS.
  [[ "$output" == *"SEAMLESS"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: --json output contains expected numeric fields and verdict
# ---------------------------------------------------------------------------

@test "seam_check: --json output contains numeric fields and verdict" {
  local clip="$WORK_DIR/clip.mp4"
  local unit="$WORK_DIR/unit_pp.mp4"
  local tiled="$WORK_DIR/tiled_pp.mp4"

  mk_clip "$clip" 220 4
  loop_unit "$clip" "$unit" --loop pingpong
  _sc_concat_n "$unit" 2 "$tiled"

  local unit_frames
  unit_frames="$(_frame_count "$unit")"

  run seam_check "$tiled" "$unit_frames" --json
  [ "$status" -eq 0 ]

  echo "output: $output"

  # Must be valid JSON with the required fields
  # Parse with awk since we have no jq dependency guaranteed
  local has_frame has_boundary has_baseline has_drop has_verdict
  has_frame="$(echo "$output" | awk -F'"frame":' 'NF>1{print "yes"}')"
  has_boundary="$(echo "$output" | awk -F'"boundary":' 'NF>1{print "yes"}')"
  has_baseline="$(echo "$output" | awk -F'"baseline":' 'NF>1{print "yes"}')"
  has_drop="$(echo "$output" | awk -F'"drop":' 'NF>1{print "yes"}')"
  has_verdict="$(echo "$output" | awk -F'"verdict":' 'NF>1{print "yes"}')"

  [ "$has_frame"    = "yes" ]
  [ "$has_boundary" = "yes" ]
  [ "$has_baseline" = "yes" ]
  [ "$has_drop"     = "yes" ]
  [ "$has_verdict"  = "yes" ]

  # Verdict field must contain a known value (SEAMLESS, SOFT, or VISIBLE)
  local verdict_val
  verdict_val="$(echo "$output" | awk -F'"verdict":"' '{print $2}' | awk -F'"' '{print $1}')"
  [[ "$verdict_val" == "SEAMLESS" || "$verdict_val" == "SOFT" || "$verdict_val" == "VISIBLE" ]]
}

# ---------------------------------------------------------------------------
# Test 5: empty/failed PSNR path → non-zero exit + stderr message
#
# Frame beyond clip length should produce empty PSNR from ffmpeg.
# seam_check must NOT silently pass with a fake SEAMLESS verdict — must exit
# non-zero and print a diagnostic to stderr.
# ---------------------------------------------------------------------------

@test "seam_check: frame beyond clip length → non-zero exit + stderr (no silent SEAMLESS)" {
  local clip="$WORK_DIR/clip.mp4"

  mk_clip "$clip" 220 3

  # 3s @ 30fps = ~90 frames; request frame 9999 which does not exist
  run --separate-stderr seam_check "$clip" 9999
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 6a: missing file → non-zero exit + stderr
# ---------------------------------------------------------------------------

@test "seam_check: missing file → non-zero exit + stderr" {
  run --separate-stderr seam_check "$WORK_DIR/no_such_file.mp4" 10
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 6b: non-integer frame → non-zero exit + stderr
# ---------------------------------------------------------------------------

@test "seam_check: non-integer frame argument → non-zero exit + stderr" {
  local clip="$WORK_DIR/clip.mp4"

  mk_clip "$clip" 220 3

  run --separate-stderr seam_check "$clip" "abc"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 6c: frame 0 → non-zero exit + stderr (FRAME must be >= 1)
# ---------------------------------------------------------------------------

@test "seam_check: frame 0 (< 1) → non-zero exit + stderr" {
  local clip="$WORK_DIR/clip.mp4"

  mk_clip "$clip" 220 3

  run --separate-stderr seam_check "$clip" 0
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 9: FRAME=1 (too close to clip start — baseline pair overlaps boundary)
#
# Root cause of the false-pass: with FRAME=1,
#   boundary pair  = (frame-1, frame) = (0, 1)
#   baseline_a     = frame-1-10 = -10, clamped to 0
#   baseline pair  = (0, 1)  ← SAME as boundary pair
#   drop = baseline_psnr - boundary_psnr = 0  → always SEAMLESS
#
# This makes FRAME=1 meaningless — every video, even a hard cut at frame 1,
# would report SEAMLESS.  The preview gate must never receive that verdict.
#
# Fix: require FRAME >= 12 so baseline_a = FRAME-11 >= 1, keeping the
# baseline pair strictly before and non-overlapping with the boundary pair.
# Frames 1–11 return non-zero + stderr "frame too close to clip start".
# ---------------------------------------------------------------------------

@test "seam_check: FRAME=1 (baseline overlaps boundary, degenerate) → non-zero exit + stderr, NOT SEAMLESS" {
  local clip="$WORK_DIR/clip.mp4"

  mk_clip "$clip" 220 3

  run --separate-stderr seam_check "$clip" 1
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
  # Must NOT print SEAMLESS — that verdict is meaningless here
  [[ "$output" != *"SEAMLESS"* ]]
}
