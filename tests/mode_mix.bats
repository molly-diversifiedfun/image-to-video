#!/usr/bin/env bats
#
# mode_mix.bats — integration tests for lib/mixer.sh::mix_clips (PRD-4)
#
# Contract:
#   mix_clips DIR TARGET_HOURS OUT
#     Folder of clips → ONE long video: clips sequenced to fill the target,
#     every junction a crossfade (xfade video + acrossfade audio), no clip
#     back-to-back with itself, reshuffled each pass.
#
#   Globals (set by make-video, defaulted here):
#     MIX_XFADE      crossfade seconds (default 1.5)
#     MIX_SEED       shuffle seed
#     MIX_ORDER      shuffle (default) | name
#     MIX_CLIP_SECS  cap each clip to N seconds (0 = whole clip)
#     MIX_HARDCUT    1 = concat with NO crossfade (fast preview/fallback)
#     MIX_ORDER_LOG  path to write the resolved clip order (one per line)
#     AUDIO_PATH     optional soundtrack replacing clip audio
#     FPS, CRF, BASE_SECS
#
#   timeline(count) = Σ dur_i − (count−1)·XFADE
#
# Clips are solid-color (distinct → measurable dissolves) + a sine tone.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

bats_require_minimum_version 1.5.0

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  source "$REPO_ROOT/lib/duration.sh"
  source "$REPO_ROOT/lib/audio.sh"
  source "$REPO_ROOT/lib/mux.sh"
  source "$REPO_ROOT/lib/classify.sh"
  source "$REPO_ROOT/lib/sequencer.sh"
  source "$REPO_ROOT/lib/mixer.sh"
  WORK_DIR="$(mktemp -d)"
  export FPS=30 CRF=18 BASE_SECS=30
  # mixer defaults (overridden per-test)
  MIX_XFADE=1.5 MIX_SEED=1 MIX_ORDER=shuffle MIX_CLIP_SECS=0 MIX_HARDCUT=0
  MIX_ORDER_LOG="" AUDIO_PATH=""
}

teardown() {
  rm -rf "$WORK_DIR"
}

# mk_color_clip OUT COLOR SECS [FREQ]  — solid color video + sine audio
mk_color_clip() {
  local out="$1" color="$2" secs="$3" freq="${4:-220}"
  "$FFMPEG" -nostdin -loglevel error -y \
    -f lavfi -i "color=c=${color}:s=320x180:r=30" \
    -f lavfi -i "sine=frequency=${freq}:sample_rate=44100" \
    -t "$secs" \
    -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p -r 30 \
    -c:a aac -b:a 64k \
    "$out"
}

# mk_clip_dir DIR  — 01_red, 02_green, 03_blue at 3s each
mk_clip_dir() {
  local dir="$1"; mkdir -p "$dir"
  mk_color_clip "$dir/01_red.mp4"   red   3 220
  mk_color_clip "$dir/02_green.mp4" green 3 330
  mk_color_clip "$dir/03_blue.mp4"  blue  3 440
}

# ---------------------------------------------------------------------------
# T1 — duration + streams.
#   name order, 3 clips × 3s, xfade 1.0, target 0.00167h (≈6s) → n=3 clips
#   (timeline(2)=5 < 6 ≤ timeline(3)=7).  Whole clips → actual = 7.0s.
# ---------------------------------------------------------------------------
@test "mix: fills to target clip count and produces a video+audio file" {
  local dir="$WORK_DIR/clips" out="$WORK_DIR/out.mp4"
  mk_clip_dir "$dir"
  MIX_XFADE=1.0 MIX_ORDER=name
  run mix_clips "$dir" 0.00167 "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  assert_has_stream "$out" v
  assert_has_stream "$out" a
  assert_duration "$out" 7.0 0.5
}

# ---------------------------------------------------------------------------
# T2 — dissolve is NOT a hard cut (positive + hard-cut negative control).
#   name order red,green,blue, xfade 1.0:
#     body_red[0,2]=2s, dissolve0[2,3]=1s, ...  dissolve0 = 0-based frames 60..89.
#   Crossfade run: assert_seam_ok inside dissolve0 PASSES (gradual blend).
#   --hardcut run: same junction is a hard cut → assert_seam_ok FAILS.
# ---------------------------------------------------------------------------
@test "mix: dissolve is a real crossfade, hardcut is not" {
  # Positive: 3-color xfade, frame 76 lands inside dissolve0 (0-based 60..89).
  local dir3="$WORK_DIR/clips"
  mk_clip_dir "$dir3"
  local out_x="$WORK_DIR/xfade.mp4"
  MIX_XFADE=1.0 MIX_ORDER=name
  run mix_clips "$dir3" 0.00167 "$out_x"
  [ "$status" -eq 0 ]
  assert_seam_ok "$out_x" 76

  # Negative control: 2 equal clips, hardcut → cut at exactly total_frames/2.
  local dir2="$WORK_DIR/two"; mkdir -p "$dir2"
  mk_color_clip "$dir2/01_red.mp4"   red   3 220
  mk_color_clip "$dir2/02_green.mp4" green 3 330
  local out_h="$WORK_DIR/hardcut.mp4"
  MIX_ORDER=name MIX_HARDCUT=1
  run mix_clips "$dir2" 0.00167 "$out_h"
  [ "$status" -eq 0 ]
  local tf mid
  tf="$("$FFPROBE" -v error -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets -of csv=p=0 "$out_h")"
  mid=$(( tf / 2 ))
  run assert_seam_ok "$out_h" "$mid"
  [ "$status" -ne 0 ]                  # hard cut → seam detected
}

# ---------------------------------------------------------------------------
# T3 — same seed reproduces the identical clip order.
# ---------------------------------------------------------------------------
@test "mix: same seed reproduces identical order" {
  local dir="$WORK_DIR/clips"; mk_clip_dir "$dir"
  local log1="$WORK_DIR/o1.txt" log2="$WORK_DIR/o2.txt"

  MIX_XFADE=1.0 MIX_SEED=42 MIX_ORDER_LOG="$log1"
  run mix_clips "$dir" 0.005 "$WORK_DIR/a.mp4"
  [ "$status" -eq 0 ]
  MIX_XFADE=1.0 MIX_SEED=42 MIX_ORDER_LOG="$log2"
  run mix_clips "$dir" 0.005 "$WORK_DIR/b.mp4"
  [ "$status" -eq 0 ]

  run diff "$log1" "$log2"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# T4 — no clip is adjacent to itself in the resolved order.
# ---------------------------------------------------------------------------
@test "mix: no adjacent repeats in the resolved order" {
  local dir="$WORK_DIR/clips"; mk_clip_dir "$dir"
  local log="$WORK_DIR/order.txt"
  MIX_XFADE=1.0 MIX_SEED=3 MIX_ORDER_LOG="$log"
  run mix_clips "$dir" 0.01 "$WORK_DIR/out.mp4"
  [ "$status" -eq 0 ]

  local prev=""
  while IFS= read -r line; do
    [ "$line" != "$prev" ] || { echo "adjacent repeat: $line"; return 1; }
    prev="$line"
  done < "$log"
}

# ---------------------------------------------------------------------------
# T5 — fewer than 2 clips is an error.
# ---------------------------------------------------------------------------
@test "mix: rejects a folder with fewer than 2 clips" {
  local dir="$WORK_DIR/one"; mkdir -p "$dir"
  mk_color_clip "$dir/01_red.mp4" red 3 220
  run mix_clips "$dir" 0.005 "$WORK_DIR/out.mp4"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# --audio replaces the clips' native sound with the music bed (FR-6).
#   Clips carry 220/330/440 Hz tones; the music bed is a 600 Hz tone. After a
#   replace the 600 Hz tone must be present and the clip tones absent.
# ---------------------------------------------------------------------------
@test "mix: --audio replaces clip audio with the music bed" {
  local dir="$WORK_DIR/clips"; mk_clip_dir "$dir"
  local music="$WORK_DIR/bed.aac"; mk_audio "$music" 600 8
  local out="$WORK_DIR/out.mp4"
  MIX_XFADE=1.0 MIX_ORDER=name AUDIO_PATH="$music"
  run mix_clips "$dir" 0.00167 "$out"
  [ "$status" -eq 0 ]
  assert_has_stream "$out" a
  assert_tone_present "$out" 600
  assert_tone_absent "$out" 220
}

# ---------------------------------------------------------------------------
# A clip shorter than 2·xfade is rejected (can't trim both ends for a junction).
# ---------------------------------------------------------------------------
@test "mix: rejects clips too short for the crossfade" {
  local dir="$WORK_DIR/clips"; mkdir -p "$dir"
  mk_color_clip "$dir/01_red.mp4"   red   1 220   # 1s clips
  mk_color_clip "$dir/02_green.mp4" green 1 330
  mk_color_clip "$dir/03_blue.mp4"  blue  1 440
  MIX_XFADE=1.0 MIX_ORDER=name        # need ≥2.05s; 1s clips fail
  run mix_clips "$dir" 0.001 "$WORK_DIR/out.mp4"
  [ "$status" -ne 0 ]
  [[ "$output" == *"too short"* ]]
}

# ---------------------------------------------------------------------------
# A source clip with NO audio track gets a silent track so junctions still mux.
# ---------------------------------------------------------------------------
@test "mix: silent (no-audio) source clips still produce an audio track" {
  local dir="$WORK_DIR/clips"; mkdir -p "$dir"
  # Video-only clips (no -c:a, no audio input).
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "color=c=red:s=320x180:r=30" \
    -t 3 -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p -r 30 "$dir/01_red.mp4"
  "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "color=c=blue:s=320x180:r=30" \
    -t 3 -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p -r 30 "$dir/02_blue.mp4"
  MIX_XFADE=1.0 MIX_ORDER=name
  run mix_clips "$dir" 0.00139 "$WORK_DIR/out.mp4"
  [ "$status" -eq 0 ]
  assert_has_stream "$WORK_DIR/out.mp4" a
}

# ---------------------------------------------------------------------------
# --clip-secs caps each clip, changing the fill count.
#   Cap 3s clips to 1.5s, xfade 0.5, target 0.00139h (≈5s):
#     timeline(n) = 1.5n − 0.5(n−1) = n + 0.5.  n=5 → 5.5 ≥ 5; n=4 → 4.5 < 5.
#   So a 1.5s cap needs 5 clips where whole 3s clips would need fewer.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# T7 — dispatch: `make-video DIR --mix HOURS --out FILE` runs the preview gate
#      and produces the final video.
# ---------------------------------------------------------------------------
@test "mix: make-video --mix dispatches, previews, and renders" {
  local dir="$WORK_DIR/clips" out="$WORK_DIR/final.mp4"
  mk_clip_dir "$dir"
  run "$REPO_ROOT/make-video" "$dir" --mix 0.00167 \
      --xfade 1.0 --order name --out "$out" --yes
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  [[ "$output" == *"PLAN"* ]]            # estimate printed
  [[ "$output" == *"preview"* ]]         # preview rendered
  assert_has_stream "$out" v
  assert_duration "$out" 7.0 0.5
}

# ---------------------------------------------------------------------------
# T8 — dispatch: --mix on a single file is rejected.
# ---------------------------------------------------------------------------
@test "mix: --mix on a single file is rejected" {
  local f="$WORK_DIR/one.mp4"
  mk_color_clip "$f" red 3 220
  run "$REPO_ROOT/make-video" "$f" --mix 0.001 --out "$WORK_DIR/o.mp4" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"directory of clips"* ]]
}

# ---------------------------------------------------------------------------
# T9 — --gpu routes the mix re-encode through VideoToolbox and still produces a
#      valid, concat-copy-clean output. On a machine without VideoToolbox the
#      tool falls back to CPU with a note; either way the render must succeed
#      and report wall-clock elapsed time. Also covers the new "rendered in Ns"
#      readout and the encoder line in the plan.
# ---------------------------------------------------------------------------
@test "mix --gpu: renders a valid file (VideoToolbox or CPU fallback) + reports elapsed" {
  local dir="$WORK_DIR/clips" out="$WORK_DIR/gpu.mp4"
  mk_clip_dir "$dir"
  run "$REPO_ROOT/make-video" "$dir" --mix 0.00167 \
      --xfade 1.0 --order name --gpu --out "$out" --yes
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  assert_has_stream "$out" v
  assert_has_stream "$out" a
  assert_duration "$out" 7.0 0.5
  [[ "$output" == *"encoder:"* ]]        # plan shows which encoder
  [[ "$output" == *"rendered in"* ]]     # elapsed readout
  # h264 either way (VideoToolbox H.264 or libx264)
  local vcodec
  vcodec="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=codec_name -of default=nw=1:nk=1 "$out")"
  [ "$vcodec" = "h264" ]
}

@test "mix: --clip-secs cap increases the clip count needed" {
  local dir="$WORK_DIR/clips"; mk_clip_dir "$dir"
  local log="$WORK_DIR/order.txt"
  MIX_XFADE=0.5 MIX_ORDER=name MIX_CLIP_SECS=1.5 MIX_ORDER_LOG="$log"
  run mix_clips "$dir" 0.00139 "$WORK_DIR/out.mp4"
  [ "$status" -eq 0 ]
  local count
  count="$(grep -c . "$log")"
  [ "$count" -eq 5 ]
}
