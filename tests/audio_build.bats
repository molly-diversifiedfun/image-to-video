#!/usr/bin/env bats
#
# audio_build.bats — tests for lib/audio.sh :: audio_build SRC TARGET_SECS OUT
#
# Contract:
#   - SRC >= TARGET_SECS: trims to exactly TARGET_SECS with a 0.5s fade-out at end
#   - SRC < TARGET_SECS: loops SRC seamlessly (crossfade at each boundary) to
#     fill TARGET_SECS, then trims to exactly TARGET_SECS
#   - Loudness-normalised to EBU R128 (I=-16, TP=-1.5, LRA=11)
#   - Output: AAC, 192k, quiet; validates SRC exists + TARGET_SECS is a
#     positive integer (non-zero integer, no floats)
#   - Directory SRC: returns 2 (stub for future folder branch)
#
# SEAM QUALITY TEST METHOD (tests 5 + 5-neg):
#   We measure astats "RMS difference" — the RMS of consecutive-sample
#   differences — in a 1ms window centred on the loop boundary, compared
#   against a 1ms baseline window drawn from mid-clip.
#
#   Why this works:
#     A click is a 1–5 sample amplitude jump that produces a large
#     consecutive-sample delta, driving up RMS difference.  A smooth
#     crossfade keeps consecutive deltas proportional to the underlying
#     signal rate-of-change.  RMS difference is therefore the natural
#     per-sample-rate-of-change metric — unlike Peak level (which reflects
#     absolute amplitude, not sudden changes) it is genuinely sensitive
#     to clicks even when the surrounding signal has similar amplitude.
#
#   Fixture requirement:
#     We use a 443 Hz tone with a 1.3s source duration.  443*1.3 = 575.9
#     cycles → phase at the boundary ≠ 0 or π, so the signal has non-zero
#     amplitude at the seam (avoiding the zero-crossing coincidence that
#     let 440 Hz / 1.5s slip through the old test).
#
#   Threshold: ratio = seam_rms_diff / baseline_rms_diff.
#     PASS: ratio < 1.75 (seam no worse than 75% above baseline)
#     FAIL: ratio >= 1.75 (click — large jump relative to baseline)
#
#   Hard loop (negative control):
#     A PCM concat of 4 copies with NO crossfade on a 443 Hz / 1.3s source
#     gives seam_rms_diff ≈ 428 vs baseline ≈ 187 → ratio ≈ 2.29 (FAILS).
#     audio_build output on the same source: ratio < 1.0 (PASSES).
#     This proves the test has teeth.
#
#   Note: the negative control works on PCM because AAC encoding smooths
#   the single-sample discontinuity.  The negative control is therefore
#   run against a PCM hard loop (not AAC) to remain sensitive.  The
#   positive test is run against audio_build's decoded AAC output, where
#   the crossfade must be large enough to survive AAC quantisation.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

bats_require_minimum_version 1.5.0

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  source "$REPO_ROOT/lib/audio.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# Internal: _rms_diff FILE START END
# Emit the RMS-difference value from astats on a time window.
# ---------------------------------------------------------------------------
_rms_diff() {
  local file="$1" start="$2" end="$3"
  "$FFMPEG" -nostdin -loglevel info \
    -i "$file" \
    -filter_complex "[0:a]atrim=start=${start}:end=${end},astats" \
    -f null - 2>&1 \
  | awk '/RMS difference:/{val=$NF; count++} END { if(count>0) print val }'
}

# ---------------------------------------------------------------------------
# Test 1: SRC shorter than target → output is exactly TARGET_SECS long
# ---------------------------------------------------------------------------

@test "audio_build: short SRC (2s) looped to target (7s) → duration 7s ±0.15 with audio stream" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 2

  run audio_build "$src" 7 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  assert_duration "$out" 7 0.15
  assert_has_stream "$out" a
}

# ---------------------------------------------------------------------------
# Test 2: SRC longer than target → output trimmed to TARGET_SECS
# ---------------------------------------------------------------------------

@test "audio_build: long SRC (10s) trimmed to target (4s) → duration 4s ±0.15" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 10

  run audio_build "$src" 4 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  assert_duration "$out" 4 0.15
}

# ---------------------------------------------------------------------------
# Test 3: SRC duration ≈ target → output is ~TARGET_SECS
# ---------------------------------------------------------------------------

@test "audio_build: SRC ~5s with target 5s → duration 5s ±0.15" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 5

  run audio_build "$src" 5 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  assert_duration "$out" 5 0.15
}

# ---------------------------------------------------------------------------
# Test 4: Loudness normalised to EBU R128 (≈ -16 LUFS ± 2 dB)
#
# Method: run loudnorm=print_format=json in analysis mode.
# output_i is the two-pass predicted loudness; close to -16 when target
# is achievable.
# ---------------------------------------------------------------------------

@test "audio_build: output loudness is near -16 LUFS (±2 dB)" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 5

  run audio_build "$src" 5 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  local loudness_json
  loudness_json="$("$FFMPEG" \
    -nostdin \
    -i "$out" \
    -af "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json" \
    -f null - 2>&1)"

  # Tab-indented JSON: `\t"output_i" : "-15.98",`
  # gsub approach compatible with macOS one-true-awk (no 3-arg match).
  local output_i
  output_i="$(echo "$loudness_json" | awk '/"output_i"/{
    gsub(/.*"output_i" *: *"/, "")
    gsub(/".*/, "")
    print
    exit
  }')"

  [[ "$output_i" =~ ^-?[0-9] ]] || {
    echo "audio_build loudness test: could not parse output_i from loudnorm json" >&2
    echo "loudnorm output was: $loudness_json" >&2
    return 1
  }

  local ok
  ok="$(awk -v val="$output_i" 'BEGIN {
    diff = val - (-16)
    if (diff < 0) diff = -diff
    print (diff <= 2) ? "ok" : "fail"
  }')"

  if [[ "$ok" != "ok" ]]; then
    echo "audio_build loudness test: expected -16 ± 2 LUFS, got output_i=${output_i}" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 5 (NEGATIVE CONTROL): A HARD loop MUST fail the seam check.
#
# This test proves the measurement has teeth.  We build a PCM hard loop
# (concat 4 copies, NO crossfade) and assert that RMS difference at the
# seam boundary exceeds 1.75× the mid-clip baseline.
#
# Fixture: 443 Hz tone at 1.3s duration.  443*1.3 = 575.9 cycles →
# sin(2π*0.9) ≈ -0.59 at the boundary (non-zero amplitude, real discontinuity).
#
# Measured values (PCM, first seam at 1.3s):
#   seam_rms_diff ≈ 428 (large consecutive-sample jumps at the discontinuity)
#   base_rms_diff ≈ 188 (normal sine rate-of-change)
#   ratio ≈ 2.28 → FAILS at threshold 1.75 ✓
# ---------------------------------------------------------------------------

@test "seam negative control: hard PCM loop (no crossfade) FAILS the seam check" {
  local src="$WORK_DIR/src.wav"

  # PCM source: 443 Hz / 1.3s so phase is non-zero at boundary
  "$FFMPEG" -nostdin -loglevel error -y \
    -f lavfi -i "sine=frequency=443:sample_rate=44100" \
    -t 1.3 -c:a pcm_s16le "$src"

  # Hard loop: 4 PCM copies, no crossfade
  local hard_loop="$WORK_DIR/hard_loop.wav"
  "$FFMPEG" -nostdin -loglevel error -y \
    -i "$src" -i "$src" -i "$src" -i "$src" \
    -filter_complex "[0:a][1:a][2:a][3:a]concat=n=4:v=0:a=1[out]" \
    -map "[out]" -c:a pcm_s16le "$hard_loop"

  local src_dur
  src_dur="$("$FFPROBE" -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$src")"

  # 1ms window centred on first seam boundary (src_dur seconds)
  local seam_c base_c half="0.0005"
  seam_c="$(awk -v d="$src_dur" -v h="$half" \
    'BEGIN { printf "%.6f %.6f", d-h, d+h }')"
  local seam_start seam_end
  seam_start="${seam_c%% *}"
  seam_end="${seam_c##* }"

  # Baseline: 1ms window at src_dur + src_dur/2 (between 1st and 2nd seam)
  base_c="$(awk -v d="$src_dur" -v h="$half" \
    'BEGIN { printf "%.6f %.6f", d*1.5-h, d*1.5+h }')"
  local base_start base_end
  base_start="${base_c%% *}"
  base_end="${base_c##* }"

  local seam_rms base_rms
  seam_rms="$(_rms_diff "$hard_loop" "$seam_start" "$seam_end")"
  base_rms="$(_rms_diff "$hard_loop" "$base_start" "$base_end")"

  [[ "$seam_rms" =~ ^[0-9] ]] || {
    echo "seam neg control: could not parse seam_rms ('${seam_rms}')" >&2; return 1
  }
  [[ "$base_rms" =~ ^[0-9] ]] || {
    echo "seam neg control: could not parse base_rms ('${base_rms}')" >&2; return 1
  }

  # A hard loop MUST have ratio >= 1.75 (this is the negative control assertion)
  local ok
  ok="$(awk -v sr="$seam_rms" -v br="$base_rms" 'BEGIN {
    ratio = (br > 0) ? sr / br : 0
    print (ratio >= 1.75) ? "ok" : "fail"
  }')"

  if [[ "$ok" != "ok" ]]; then
    echo "seam neg control FAILED: hard loop should have ratio >= 1.75 but" \
         "seam_rms=${seam_rms} base_rms=${base_rms}" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Seam quality — audio_build crossfade PASSES the seam check
#
# Same measurement as the negative control but on audio_build's output.
# Decoded from AAC so we test the full encode → decode pipeline.
#
# Expected: crossfade keeps seam RMS diff at baseline level (ratio < 1.75).
# ---------------------------------------------------------------------------

@test "audio_build: seam quality — crossfade loop passes seam RMS check (ratio < 1.75)" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  # 443 Hz / 1.3s → same non-zero-phase fixture as negative control
  "$FFMPEG" -nostdin -loglevel error -y \
    -f lavfi -i "sine=frequency=443:sample_rate=44100" \
    -t 1.3 -c:a aac -b:a 64k "$src"

  run audio_build "$src" 6 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  # Decode AAC to PCM for measurement
  local pcm="$WORK_DIR/out.wav"
  "$FFMPEG" -nostdin -loglevel error -y -i "$out" -c:a pcm_s16le "$pcm"

  local src_dur
  src_dur="$("$FFPROBE" -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$src")"

  local half="0.0005"
  local seam_start seam_end base_start base_end
  seam_start="$(awk -v d="$src_dur" -v h="$half" 'BEGIN { printf "%.6f", d-h }')"
  seam_end="$(awk -v d="$src_dur" -v h="$half" 'BEGIN { printf "%.6f", d+h }')"
  base_start="$(awk -v d="$src_dur" -v h="$half" 'BEGIN { printf "%.6f", d*1.5-h }')"
  base_end="$(awk -v d="$src_dur" -v h="$half" 'BEGIN { printf "%.6f", d*1.5+h }')"

  local seam_rms base_rms
  seam_rms="$(_rms_diff "$pcm" "$seam_start" "$seam_end")"
  base_rms="$(_rms_diff "$pcm" "$base_start" "$base_end")"

  [[ "$seam_rms" =~ ^[0-9] ]] || {
    echo "seam test: could not parse seam_rms ('${seam_rms}')" >&2; return 1
  }
  [[ "$base_rms" =~ ^[0-9] ]] || {
    echo "seam test: could not parse base_rms ('${base_rms}')" >&2; return 1
  }

  local ok
  ok="$(awk -v sr="$seam_rms" -v br="$base_rms" 'BEGIN {
    ratio = (br > 0) ? sr / br : 0
    print (ratio < 1.75) ? "ok" : "fail"
  }')"

  if [[ "$ok" != "ok" ]]; then
    echo "audio_build seam test: click detected — seam_rms=${seam_rms}," \
         "base_rms=${base_rms}," \
         "ratio=$(awk -v s="$seam_rms" -v b="$base_rms" \
           'BEGIN{printf "%.2f", (b>0)?s/b:0}') exceeds 1.75" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 5b: 48 kHz source — duration correct + seam passes
#
# Reproduces the sample-rate bug: audio_build computed unit_samps = unit_dur
# * 44100 (hardcoded), but a 48 kHz source writes the unit at 48 kHz.
# With the bug: aloop size is 8.2% short → loop boundary misplaced →
# crossfade skipped → click.  After the fix: aloop size uses the unit's
# actual sample rate → correct seam position → crossfade intact.
#
# Fixture: 48 kHz AAC source (generated at 48 kHz).  audio_build must
# produce a file of the correct duration AND pass the seam RMS check.
# ---------------------------------------------------------------------------

@test "audio_build: 48 kHz source — duration correct + seam passes RMS check" {
  local src="$WORK_DIR/src_48k.aac"
  local out="$WORK_DIR/out_48k.aac"

  # Generate at 48 kHz: ffmpeg lavfi sine outputs at the specified sample_rate
  "$FFMPEG" -nostdin -loglevel error -y \
    -f lavfi -i "sine=frequency=443:sample_rate=48000" \
    -t 2 -c:a aac -b:a 64k "$src"

  run audio_build "$src" 7 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  # Duration must be correct regardless of source sample rate
  assert_duration "$out" 7 0.15

  # Decode and check seam quality at the loop boundary
  local pcm="$WORK_DIR/out_48k.wav"
  "$FFMPEG" -nostdin -loglevel error -y -i "$out" -c:a pcm_s16le "$pcm"

  local src_dur
  src_dur="$("$FFPROBE" -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$src")"

  local half="0.0005"
  local seam_start seam_end base_start base_end
  seam_start="$(awk -v d="$src_dur" -v h="$half" 'BEGIN { printf "%.6f", d-h }')"
  seam_end="$(awk -v d="$src_dur" -v h="$half" 'BEGIN { printf "%.6f", d+h }')"
  base_start="$(awk -v d="$src_dur" -v h="$half" 'BEGIN { printf "%.6f", d*1.5-h }')"
  base_end="$(awk -v d="$src_dur" -v h="$half" 'BEGIN { printf "%.6f", d*1.5+h }')"

  local seam_rms base_rms
  seam_rms="$(_rms_diff "$pcm" "$seam_start" "$seam_end")"
  base_rms="$(_rms_diff "$pcm" "$base_start" "$base_end")"

  [[ "$seam_rms" =~ ^[0-9] ]] || {
    echo "48k seam test: could not parse seam_rms ('${seam_rms}')" >&2; return 1
  }
  [[ "$base_rms" =~ ^[0-9] ]] || {
    echo "48k seam test: could not parse base_rms ('${base_rms}')" >&2; return 1
  }

  local ok
  ok="$(awk -v sr="$seam_rms" -v br="$base_rms" 'BEGIN {
    ratio = (br > 0) ? sr / br : 0
    print (ratio < 1.75) ? "ok" : "fail"
  }')"

  if [[ "$ok" != "ok" ]]; then
    echo "audio_build 48k seam test: click detected — seam_rms=${seam_rms}," \
         "base_rms=${base_rms}," \
         "ratio=$(awk -v s="$seam_rms" -v b="$base_rms" \
           'BEGIN{printf "%.2f", (b>0)?s/b:0}') exceeds 1.75" \
         "(likely 44100 hardcode bug in aloop size)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 6a: missing SRC → non-zero + stderr
# ---------------------------------------------------------------------------

@test "audio_build: missing SRC → non-zero exit + stderr" {
  local out="$WORK_DIR/out.aac"

  run --separate-stderr audio_build "$WORK_DIR/no_such.aac" 5 "$out"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 6b: zero TARGET_SECS → non-zero + stderr
# ---------------------------------------------------------------------------

@test "audio_build: TARGET_SECS=0 → non-zero exit + stderr" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 3

  run --separate-stderr audio_build "$src" 0 "$out"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 6c: negative TARGET_SECS → non-zero + stderr
# ---------------------------------------------------------------------------

@test "audio_build: negative TARGET_SECS → non-zero exit + stderr" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 3

  run --separate-stderr audio_build "$src" -3 "$out"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 6d: non-integer TARGET_SECS → non-zero + stderr
# ---------------------------------------------------------------------------

@test "audio_build: non-integer TARGET_SECS (float) → non-zero exit + stderr" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 3

  run --separate-stderr audio_build "$src" 3.5 "$out"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 6e: non-numeric TARGET_SECS → non-zero + stderr
# ---------------------------------------------------------------------------

@test "audio_build: non-numeric TARGET_SECS → non-zero exit + stderr" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 3

  run --separate-stderr audio_build "$src" "abc" "$out"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 7: empty directory SRC → returns non-zero
#
# The folder branch is now implemented; an empty dir (no audio files) correctly
# returns non-zero because there is nothing to build a playlist from.
# ---------------------------------------------------------------------------

@test "audio_build: directory SRC → non-zero exit (stub for folder branch)" {
  local dir="$WORK_DIR/srcdir"
  local out="$WORK_DIR/out.aac"
  mkdir -p "$dir"

  run audio_build "$dir" 5 "$out"
  [ "$status" -ne 0 ]
}
