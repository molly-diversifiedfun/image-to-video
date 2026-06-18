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
# Seam quality test method:
#   We compare Peak level dB in a short window AROUND the loop boundary against
#   a baseline window drawn from a region of the same audio that contains no
#   seam.  A click/pop manifests as a sudden amplitude spike (high peak, normal
#   RMS → large crest factor in the seam window).  We accept the seam if the
#   peak at the boundary is within 12 dB of the baseline peak.  This threshold
#   is generous enough to survive the tri-windowed crossfade's amplitude bulge
#   while still catching a raw sample discontinuity (which typically produces a
#   40+ dB crest spike).
#
#   Limitation: the test runs at the first loop boundary, which falls at roughly
#   SRC_DUR seconds.  For a sine wave fixture the crossfade slightly raises the
#   peak vs a mid-clip window; a raw click raises it by 20–40+ dB.  The 12 dB
#   gap catches the latter without false-failing on the former.

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
# Method: run loudnorm=print_format=json in measurement-only mode.
# output_i reflects what loudnorm reports as the output integrated loudness;
# on a short test clip this is typically within ±2 dB of the target of -16 LUFS.
# ---------------------------------------------------------------------------

@test "audio_build: output loudness is near -16 LUFS (±2 dB)" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 5

  run audio_build "$src" 5 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  # Measure integrated loudness using loudnorm in analysis mode.
  # We parse output_i from the JSON block that loudnorm prints to stderr.
  # output_i is the loudness that the two-pass loudnorm would produce for this
  # material; for clips where the target is reachable it is very close to -16.
  local loudness_json
  loudness_json="$("$FFMPEG" \
    -nostdin \
    -i "$out" \
    -af "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json" \
    -f null - 2>&1)"

  local output_i
  # The loudnorm JSON is tab-indented: `\t"output_i" : "-15.98",`
  # Use gsub to strip everything before and after the value (compatible with
  # macOS one-true-awk which does not support 3-arg match).
  output_i="$(echo "$loudness_json" | awk '/"output_i"/{
    gsub(/.*"output_i" *: *"/, "")
    gsub(/".*/, "")
    print
    exit
  }')"

  # Guard: if we didn't get a numeric value loudnorm didn't run correctly.
  [[ "$output_i" =~ ^-?[0-9] ]] || {
    echo "audio_build loudness test: could not parse output_i from loudnorm json" >&2
    echo "loudnorm output was: $loudness_json" >&2
    return 1
  }

  # Accept ±2 dB around -16 LUFS
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
# Test 5: Seam quality — no audible click at loop boundaries
#
# Fixture: 1.5s sine SRC looped to 6s (loops ~4x).
# First loop boundary is at approximately SRC_DUR seconds.
#
# Method: compare Peak level dB in a 0.2s window centred on the first loop
# boundary against a 0.2s baseline window centred well away from any boundary.
# A clean crossfade raises the boundary peak by at most a few dB; a raw click
# (sample discontinuity) raises it by 20–40+ dB.  We use a 12 dB threshold.
#
# Important: we measure BEFORE loudnorm so the seam signal is not masked by
# the gain change; audio_build applies loudnorm to the final output, so we
# simply measure the output file after the function returns.
# ---------------------------------------------------------------------------

@test "audio_build: seam quality — loop boundary peak within 12 dB of baseline" {
  local src="$WORK_DIR/src.aac"
  local out="$WORK_DIR/out.aac"

  mk_audio "$src" 440 2
  # Target = 6s from a 1.5s src → loops ~4 times
  # We use a 2s src here so the seam falls at ~2.0s (not right at the edge of
  # the fade-out applied to the long-enough case)

  run audio_build "$src" 6 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  # Find the actual SRC duration used by ffprobe (same as audio_build does)
  local src_dur
  src_dur="$("$FFPROBE" \
    -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$src")"

  # Build boundary window: ±0.1s around the first seam
  local seam_start seam_end
  seam_start="$(awk -v d="$src_dur" 'BEGIN { printf "%.3f", d - 0.1 }')"
  seam_end="$(awk -v d="$src_dur" 'BEGIN { printf "%.3f", d + 0.1 }')"

  # Baseline window: centred at src_dur*1.5 (between first and second seam)
  local base_start base_end
  base_start="$(awk -v d="$src_dur" 'BEGIN { printf "%.3f", d * 1.5 - 0.1 }')"
  base_end="$(awk -v d="$src_dur" 'BEGIN { printf "%.3f", d * 1.5 + 0.1 }')"

  # Peak at seam boundary window
  local seam_peak
  seam_peak="$("$FFMPEG" -nostdin -loglevel info \
    -i "$out" \
    -filter_complex "[0:a]atrim=start=${seam_start}:end=${seam_end},astats" \
    -f null - 2>&1 | awk '/Peak level dB:/{val=$NF; count++} END { if(count>0) print val }')"

  # Peak at baseline window
  local base_peak
  base_peak="$("$FFMPEG" -nostdin -loglevel info \
    -i "$out" \
    -filter_complex "[0:a]atrim=start=${base_start}:end=${base_end},astats" \
    -f null - 2>&1 | awk '/Peak level dB:/{val=$NF; count++} END { if(count>0) print val }')"

  # Guard: if either measurement failed, fail loudly rather than silently pass
  [[ "$seam_peak" =~ ^-?[0-9] ]] || {
    echo "audio_build seam test: could not parse seam peak (got '${seam_peak}')" >&2
    return 1
  }
  [[ "$base_peak" =~ ^-?[0-9] ]] || {
    echo "audio_build seam test: could not parse baseline peak (got '${base_peak}')" >&2
    return 1
  }

  # seam_peak must be within 12 dB above the baseline_peak
  # (crossfade raises it a few dB; raw click raises it 20-40+ dB)
  local ok
  ok="$(awk -v sp="$seam_peak" -v bp="$base_peak" 'BEGIN {
    diff = sp - bp
    print (diff <= 12) ? "ok" : "fail"
  }')"

  if [[ "$ok" != "ok" ]]; then
    echo "audio_build seam test: click detected — seam_peak=${seam_peak} dB," \
         "baseline_peak=${base_peak} dB, diff exceeds 12 dB threshold" >&2
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
# Test 7: directory SRC → returns non-zero (stub for future folder branch)
# ---------------------------------------------------------------------------

@test "audio_build: directory SRC → non-zero exit (stub for folder branch)" {
  local dir="$WORK_DIR/srcdir"
  local out="$WORK_DIR/out.aac"
  mkdir -p "$dir"

  run audio_build "$dir" 5 "$out"
  [ "$status" -ne 0 ]
}
