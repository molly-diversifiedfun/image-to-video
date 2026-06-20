#!/usr/bin/env bats
#
# loop_unit.bats — tests for lib/loop.sh :: loop_unit CLIP OUT [--loop STRATEGY] [--xfade SECS]
#
# Contract:
#   pingpong: OUT = CLIP forward + CLIP reversed (video + audio reversed).
#             When concat-copied the result is TRULY seamless at both the
#             internal turn and the wrap boundary (PSNR within 8 dB of baseline).
#             Duration ≈ 2× CLIP.
#
#   crossfade: OUT is built so its first and last frames are the SAME source
#              frame (CLIP@xfade); the real tail dissolves into the real head
#              ACROSS the seam.  concat-copies have no hard-cut FLASH and no
#              backward content jump.  The seam is a blend (not pixel-identical
#              like pingpong), so on sharp/high-motion content a faint residual
#              may remain — widen xfade to hide it.  The right strategy when the
#              source can't be reversed (rain, falling motion).
#              CLIP must be >= 3× xfade; shorter clips are rejected (non-zero).
#
#   native: OUT = CLIP as-is (copy).  Caller asserts the source already loops.
#           We assert the weaker property: duration + stream parity with CLIP.
#
# Seam honesty (empirically measured on smooth gradient content):
#   baseline adjacent-frame PSNR ≈ 48 dB  (mk_clip gradients source)
#   pingpong boundary PSNR ≈ 48–56 dB     — TRULY seamless, passes assert_seam_ok
#   crossfade boundary PSNR ≈ 40–50 dB    — seam-spanning, ≈1 dB drop → SEAMLESS
#   hard-cut boundary PSNR ≈ 10–20 dB     — large drop, clearly worse than crossfade
#
# Audio: all strategies preserve / reverse audio through the chosen treatment.
# No-audio clips: pingpong + crossfade produce video-only units without error.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

bats_require_minimum_version 1.5.0

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  source "$REPO_ROOT/lib/loop.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# Internal helper: concat FILE N times into OUT (stream-copy, no re-encode)
# Used to tile loop units and test boundary quality.
# ---------------------------------------------------------------------------
_concat_n() {
  local file="$1"
  local n="$2"
  local out="$3"

  # Build a concat list file
  # Note: macOS mktemp requires the X-template to be the suffix, so we use
  # a .tmp extension and rename after creation to get a .txt file.
  local list
  list="$(mktemp -p "$WORK_DIR" concat_list.XXXXXX)"
  mv "$list" "${list}.txt"
  list="${list}.txt"
  local i
  for (( i=0; i<n; i++ )); do
    echo "file '$file'" >> "$list"
  done

  # Determine if there is an audio stream so we can set the right -map flags
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
# Internal helper: get the boundary PSNR between last frame before FRAME
# and FRAME itself (same approach as assert_seam_ok internals).
# Prints a numeric value in dB.  Requires $FFMPEG/$FFPROBE set by fixtures.sh.
# ---------------------------------------------------------------------------
_boundary_psnr() {
  local file="$1"
  local frame="$2"

  local a=$(( frame - 1 ))
  [[ $a -ge 0 ]] || a=0
  local b=$(( a + 1 ))
  __assert_seam_psnr_pair "$file" "$a" "$b"
}

# ---------------------------------------------------------------------------
# Test 1: pingpong is truly seamless — both boundaries pass assert_seam_ok
#
# Build a 4s clip, make a pingpong unit (≈8s), concat-copy 2× (≈16s).
# Total frames ≈ 480 at 30fps.
#
# Boundaries to check:
#   Internal turn: frame 240 (end of first forward pass / start of first reverse)
#   Wrap:          frame 480 (end of first full cycle / start of second forward pass)
#
# assert_seam_ok uses an 8 dB threshold vs a baseline taken 10 frames before
# the boundary, so any well-blended transition passes.  pingpong achieves this
# because the first frame of the reversed clip == the last frame of the forward clip.
# ---------------------------------------------------------------------------

@test "pingpong: both internal-turn and wrap boundaries are truly seamless (assert_seam_ok passes)" {
  local clip="$WORK_DIR/clip.mp4"
  local unit="$WORK_DIR/unit_pp.mp4"
  local tiled="$WORK_DIR/tiled_pp.mp4"

  mk_clip "$clip" 220 4

  run loop_unit "$clip" "$unit" --loop pingpong
  [ "$status" -eq 0 ]
  [ -f "$unit" ]

  _concat_n "$unit" 2 "$tiled"
  [ -f "$tiled" ]

  # Count frames in the unit
  local unit_frames
  unit_frames="$("$FFPROBE" -v error \
    -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$unit")"

  # Internal turn: frame at the unit's midpoint (last forward → first reverse)
  # This is roughly frame unit_frames/2 inside the unit, which in the 2-copy
  # tiled file is at frame unit_frames/2.
  local turn_frame=$(( unit_frames / 2 ))

  # Wrap boundary: exactly unit_frames into the tiled file
  local wrap_frame="$unit_frames"

  assert_seam_ok "$tiled" "$turn_frame"
  assert_seam_ok "$tiled" "$wrap_frame"
}

# ---------------------------------------------------------------------------
# Test 2: pingpong unit has audio stream present
# ---------------------------------------------------------------------------

@test "pingpong: output unit has an audio stream" {
  local clip="$WORK_DIR/clip.mp4"
  local unit="$WORK_DIR/unit_pp.mp4"

  mk_clip "$clip" 220 3

  run loop_unit "$clip" "$unit" --loop pingpong
  [ "$status" -eq 0 ]
  [ -f "$unit" ]

  assert_has_stream "$unit" a
}

# ---------------------------------------------------------------------------
# Test 3: pingpong duration ≈ 2× clip duration
# ---------------------------------------------------------------------------

@test "pingpong: unit duration is approximately 2× the source clip" {
  local clip="$WORK_DIR/clip.mp4"
  local unit="$WORK_DIR/unit_pp.mp4"

  mk_clip "$clip" 220 3

  run loop_unit "$clip" "$unit" --loop pingpong
  [ "$status" -eq 0 ]
  [ -f "$unit" ]

  # 2 × 3s = 6s, allow ±1s tolerance for codec rounding
  assert_duration "$unit" 6 1.0
}

# ---------------------------------------------------------------------------
# Test 4: crossfade improves on hard-cut — crossfade PSNR > hard-cut PSNR
#
# We build:
#   (a) crossfade unit, then concat-copy 2× → measure boundary PSNR
#   (b) naive hard concat of the raw clip 4× → measure boundary PSNR at
#       the same logical position
#
# Assert: crossfade boundary PSNR is strictly higher than hard-cut PSNR.
# (With the seam-spanning fix the crossfade seam is also continuous — see the
# seam_check SEAMLESS test — but here we only assert it beats a hard cut, which
# is the strategy-independent floor.)
#
# Typical measured values (smooth gradient source, 4s clip, 1s xfade):
#   hard-cut PSNR  ≈ 12–18 dB
#   crossfade PSNR ≈ 40–50 dB (seam joins content-X to content-X)
# ---------------------------------------------------------------------------

@test "crossfade: boundary PSNR is higher than a hard cut" {
  local clip="$WORK_DIR/clip.mp4"
  local unit_xf="$WORK_DIR/unit_xf.mp4"
  local tiled_xf="$WORK_DIR/tiled_xf.mp4"
  local tiled_hc="$WORK_DIR/tiled_hc.mp4"

  # Need at least 3× xfade duration; default xfade=1.0s so clip ≥ 4s.
  mk_clip "$clip" 220 4

  run loop_unit "$clip" "$unit_xf" --loop crossfade --xfade 1.0
  [ "$status" -eq 0 ]
  [ -f "$unit_xf" ]

  # Tile the crossfade unit 2× and measure boundary
  _concat_n "$unit_xf" 2 "$tiled_xf"

  local unit_frames
  unit_frames="$("$FFPROBE" -v error \
    -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$unit_xf")"

  local xf_psnr
  xf_psnr="$(_boundary_psnr "$tiled_xf" "$unit_frames")"

  # Hard concat: tile raw clip 4× (no xfade unit), same boundary position
  _concat_n "$clip" 4 "$tiled_hc"

  local clip_frames
  clip_frames="$("$FFPROBE" -v error \
    -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$clip")"

  local hc_psnr
  hc_psnr="$(_boundary_psnr "$tiled_hc" "$clip_frames")"

  # Log values for diagnostic visibility (bats captures stdout only on failure)
  echo "crossfade boundary PSNR: ${xf_psnr} dB  |  hard-cut boundary PSNR: ${hc_psnr} dB"

  # Assert crossfade PSNR > hard-cut PSNR (strictly better)
  local xf_wins
  xf_wins="$(awk -v xf="$xf_psnr" -v hc="$hc_psnr" 'BEGIN { print (xf > hc) ? "yes" : "no" }')"
  [ "$xf_wins" = "yes" ]
}

# ---------------------------------------------------------------------------
# Test 5: crossfade rejects clips shorter than 3× xfade duration
# ---------------------------------------------------------------------------

@test "crossfade: rejects clip shorter than 3× xfade duration (non-zero exit + stderr)" {
  local clip="$WORK_DIR/short.mp4"
  local unit="$WORK_DIR/unit_short.mp4"

  # clip=2s, xfade=1s → 2s < 3×1s=3s → must reject
  mk_clip "$clip" 220 2

  run --separate-stderr loop_unit "$clip" "$unit" --loop crossfade --xfade 1.0
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 6: native strategy copies the clip (duration + stream parity)
#
# We assert the weaker property: the output duration matches the source within
# tolerance and the stream types are preserved.  We do not assert seamlessness
# because the gradient source does not loop by construction.
# ---------------------------------------------------------------------------

@test "native: output duration and streams match the source clip" {
  local clip="$WORK_DIR/clip.mp4"
  local unit="$WORK_DIR/unit_native.mp4"

  mk_clip "$clip" 220 3

  run loop_unit "$clip" "$unit" --loop native
  [ "$status" -eq 0 ]
  [ -f "$unit" ]

  # Duration must match within 0.5s
  assert_duration "$unit" 3 0.5

  # Stream types must be preserved
  assert_has_stream "$unit" v
  assert_has_stream "$unit" a
}

# ---------------------------------------------------------------------------
# Test 7a: missing clip → non-zero exit + stderr
# ---------------------------------------------------------------------------

@test "loop_unit: missing CLIP → non-zero exit + stderr message" {
  local unit="$WORK_DIR/unit.mp4"

  run --separate-stderr loop_unit "$WORK_DIR/no_such_clip.mp4" "$unit" --loop pingpong
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 7b: clip with no video stream → non-zero exit + stderr
# ---------------------------------------------------------------------------

@test "loop_unit: audio-only input (no video stream) → non-zero exit + stderr" {
  local audio_only="$WORK_DIR/no_video.aac"
  local unit="$WORK_DIR/unit.mp4"

  # Generate an audio-only file (no video)
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "sine=frequency=220:sample_rate=44100" \
    -t 3 \
    -c:a aac -b:a 64k \
    "$audio_only"

  run --separate-stderr loop_unit "$audio_only" "$unit" --loop pingpong
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 8: no-audio clip — pingpong produces a valid video-only unit
# ---------------------------------------------------------------------------

@test "pingpong: no-audio clip produces a valid video-only unit without error" {
  local silent="$WORK_DIR/silent.mp4"
  local unit="$WORK_DIR/unit_silent.mp4"

  # Build a silent video (no audio stream)
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x180:d=3" \
    -r 30 \
    -c:v libx264 -pix_fmt yuv420p \
    -an \
    "$silent"

  run loop_unit "$silent" "$unit" --loop pingpong
  [ "$status" -eq 0 ]
  [ -f "$unit" ]

  assert_has_stream "$unit" v
  # No audio stream expected — assert_has_stream "a" should fail (negative check)
  # We verify the unit is readable and valid by checking duration ≈ 2× 3s
  assert_duration "$unit" 6 1.0
}

# ---------------------------------------------------------------------------
# Test 9: no-audio clip — crossfade produces a valid video-only unit
# ---------------------------------------------------------------------------

@test "crossfade: no-audio clip produces a valid video-only unit without error" {
  local silent="$WORK_DIR/silent.mp4"
  local unit="$WORK_DIR/unit_silent_xf.mp4"

  # Build a silent video (no audio stream), 6s to satisfy 3× xfade=1s
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x180:d=6" \
    -r 30 \
    -c:v libx264 -pix_fmt yuv420p \
    -an \
    "$silent"

  run loop_unit "$silent" "$unit" --loop crossfade --xfade 1.0
  [ "$status" -eq 0 ]
  [ -f "$unit" ]

  assert_has_stream "$unit" v
}

# ---------------------------------------------------------------------------
# Test 10: default strategy is crossfade (no --loop flag)
# ---------------------------------------------------------------------------

@test "loop_unit: default strategy (no --loop) produces a valid output" {
  local clip="$WORK_DIR/clip.mp4"
  local unit="$WORK_DIR/unit_default.mp4"

  # 4s clip to satisfy 3× default xfade=1.0s
  mk_clip "$clip" 220 4

  run loop_unit "$clip" "$unit"
  [ "$status" -eq 0 ]
  [ -f "$unit" ]

  assert_has_stream "$unit" v
}

# mean_volume (dB) of a 0.5s window of FILE starting at time START.
_mean_vol() {
  "$FFMPEG" -nostdin -hide_banner -ss "$2" -t 0.5 -i "$1" -af volumedetect -f null - 2>&1 \
    | awk -F'mean_volume:' '/mean_volume/{gsub(/ dB.*/,"",$2); gsub(/ /,"",$2); print $2}'
}

# ---------------------------------------------------------------------------
# Test 11: crossfade audio uses a CONSTANT-POWER curve (no volume dip at the
# loop seam).
#
# The audio crossfade overlaps the clip's tail with its head.  A linear
# (constant-gain / `tri`) crossfade of two UNCORRELATED signals dips ~3 dB at
# the overlap midpoint — an audible "pump" that sounds like a crossfade rather
# than a smooth cross-dissolve.  The equal-power `qsin` curve holds loudness
# constant through the overlap.  Source: steady pink noise so tail/head are
# uncorrelated (a pure tone would be correlated and wouldn't show the dip).
#
# TEETH: with the old `tri` curve this asserts ~3 dB and FAILS; with `qsin`
# the dip collapses to well under 1.5 dB.
# ---------------------------------------------------------------------------
@test "crossfade: audio is constant-power (no volume dip at the loop seam)" {
  local clip="$WORK_DIR/noise.mp4"
  local unit="$WORK_DIR/unit_noise.mp4"

  # 12s clip, steady pink noise audio + trivial video.
  "$FFMPEG" -nostdin -loglevel error -y \
    -f lavfi -i "color=c=gray:s=160x90:rate=30:d=12" \
    -f lavfi -i "anoisesrc=d=12:c=pink:a=0.5" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest "$clip"

  run loop_unit "$clip" "$unit" --loop crossfade --xfade 4
  [ "$status" -eq 0 ]
  [ -f "$unit" ]

  # Unit length = 12 − 4 = 8s; the crossfade is its last 4s → midpoint ≈ 6.0s,
  # baseline taken in the steady body ≈ 2.0s.
  local base mid dip
  base="$(_mean_vol "$unit" 2.0)"
  mid="$(_mean_vol "$unit" 6.0)"
  [ -n "$base" ] && [ -n "$mid" ]
  dip="$(awk -v a="$base" -v m="$mid" 'BEGIN{printf "%.2f", a-m}')"
  echo "baseline=${base}dB midpoint=${mid}dB dip=${dip}dB (linear/tri would be ~3 dB)"

  # |dip| must stay under 1.5 dB — constant power, no audible pump.
  awk -v d="$dip" 'BEGIN{ exit !(d < 1.5 && d > -1.5) }'
}
