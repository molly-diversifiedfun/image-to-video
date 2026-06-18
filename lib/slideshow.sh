#!/usr/bin/env bash
#
# lib/slideshow.sh — xfade_join DIR EACH_HOURS OUT
#
# Build ONE long video from a folder of images where:
#   - each image is held for EACH_HOURS (fractional hours)
#   - consecutive images crossfade (soft dissolve) into each other
#
# Total duration = Σ(each_i) − (n−1)×xfade
# where each_i = EACH_HOURS for all images (uniform hold).
#
# Algorithm (n images, hold E seconds each, dissolve X seconds):
#   1. Normalize each image to PW×PH (project resolution from first image).
#      Default (fit): scale with letterbox pad.
#      --fill: scale with crop.
#   2. Build hold segments (encode-once base + concat-copy, mirroring make_static):
#      hold_0     = E − X       (first)
#      hold_i     = E − 2X     (interior)
#      hold_{n-1} = E − X       (last)
#      Validate all holds > 0 before encoding.
#   3. Build dissolve clips (d_i) for i=0..n-2, each X seconds:
#      xfade transition from image_i → image_{i+1}
#   4. Concat-copy the ordered sequence:
#      hold_0, d_0, hold_1, d_1, …, hold_{n-1}
#   5. If --audio, build audio to total_secs then mux.
#   6. Degenerate case (n==1): build a static video of the single image.
#
# DEPENDENCIES
# ────────────
#   $FFMPEG, $FFPROBE must be set by the caller (fixtures.sh or make-video).
#   Functions: die, img_dims, audio_build, mux_audio (in make-video or sourced libs).
#   Globals: FPS, CRF, BASE_SECS (all set in make-video).
#   bash 3.2+; awk for float arithmetic.

# ---------------------------------------------------------------------------
# _slideshow_vf PW PH FILL
#
# Emit the normalized video filter string for a PW×PH output.
# FILL=0 → letterbox (fit): scale to fit, pad with black bars.
# FILL=1 → crop (fill): scale to cover, then crop to exact size.
# ---------------------------------------------------------------------------
_slideshow_vf() {
  local pw="$1" ph="$2" fill="${3:-0}"
  if [[ "$fill" -eq 1 ]]; then
    echo "scale=${pw}:${ph}:force_original_aspect_ratio=increase,crop=${pw}:${ph},format=yuv420p"
  else
    echo "scale=${pw}:${ph}:force_original_aspect_ratio=decrease,pad=${pw}:${ph}:(ow-iw)/2:(oh-ih)/2,format=yuv420p"
  fi
}

# ---------------------------------------------------------------------------
# _slideshow_encode_base IMG OUT PW PH FILL SECS
#
# Encode a single still image into a base segment of SECS seconds.
# Produces a single-keyframe H.264 segment: cheap to encode, fast to concat-copy.
# Same codec/fps/pixfmt used for holds and as the base for _slideshow_build_hold.
# ---------------------------------------------------------------------------
_slideshow_encode_base() {
  local img="$1" out="$2" pw="$3" ph="$4" fill="${5:-0}" secs="${6:-$BASE_SECS}"
  local vf; vf="$(_slideshow_vf "$pw" "$ph" "$fill")"

  "$FFMPEG" -nostdin -loglevel error -y \
    -loop 1 -framerate "$FPS" -t "$secs" -i "$img" \
    -vf "$vf" \
    -c:v libx264 -preset ultrafast -crf "$CRF" \
    -g 999999 -keyint_min 999999 -sc_threshold 0 \
    -an -movflags +faststart \
    "$out"
}

# ---------------------------------------------------------------------------
# _slideshow_build_hold IMG OUT PW PH FILL HOLD_SECS TMP_DIR
#
# Build a hold segment of HOLD_SECS seconds for IMG using encode-once+concat-copy.
# Mirrors make_static's strategy so render time is O(1) in hold length, not O(n).
#
# If HOLD_SECS <= BASE_SECS: single encode (trivial path).
# Else: encode ONE BASE_SECS base once, concat-copy floor(HOLD_SECS/BASE_SECS)
#       copies, append a fractional remainder if needed, output via -c copy.
# All segments use identical codec/fps/pixfmt so the outer concat-copy succeeds.
# ---------------------------------------------------------------------------
_slideshow_build_hold() {
  local img="$1" out="$2" pw="$3" ph="$4" fill="${5:-0}"
  local hold_secs="$6"
  local tmp_dir="$7"

  # Determine if we need the loop path (hold > BASE_SECS)
  local needs_loop
  needs_loop="$(awk -v h="$hold_secs" -v b="$BASE_SECS" \
    'BEGIN { print (h > b) ? "1" : "0" }')"

  if [[ "$needs_loop" == "0" ]]; then
    # Short hold: single encode (float -t accepted by ffmpeg)
    _slideshow_encode_base "$img" "$out" "$pw" "$ph" "$fill" "$hold_secs"
    return $?
  fi

  # Long hold: encode-once base, then concat-copy
  local base_file
  base_file="$tmp_dir/base_$(basename "$out").mp4"
  _slideshow_encode_base "$img" "$base_file" "$pw" "$ph" "$fill" "$BASE_SECS" \
    || return 1

  local loops rem_secs
  loops="$(awk -v h="$hold_secs" -v b="$BASE_SECS" 'BEGIN { printf "%d", int(h / b) }')"
  rem_secs="$(awk -v h="$hold_secs" -v b="$BASE_SECS" -v l="$loops" \
    'BEGIN { printf "%.6f", h - l * b }')"

  local list_file
  list_file="$tmp_dir/hold_list_$(basename "$out").txt"
  : > "$list_file"
  local j
  for (( j=0; j<loops; j++ )); do
    printf "file '%s'\n" "$base_file" >> "$list_file"
  done

  # Fractional remainder: encode a short tail segment if rem_secs > 0.01
  local has_rem
  has_rem="$(awk -v r="$rem_secs" 'BEGIN { print (r > 0.01) ? "1" : "0" }')"
  if [[ "$has_rem" == "1" ]]; then
    local rem_file
    rem_file="$tmp_dir/rem_$(basename "$out").mp4"
    _slideshow_encode_base "$img" "$rem_file" "$pw" "$ph" "$fill" "$rem_secs" \
      || return 1
    printf "file '%s'\n" "$rem_file" >> "$list_file"
  fi

  "$FFMPEG" -nostdin -loglevel error -y \
    -f concat -safe 0 -i "$list_file" \
    -c copy \
    -movflags +faststart \
    "$out"
}

# ---------------------------------------------------------------------------
# _slideshow_make_dissolve IMG_A IMG_B OUT PW PH XFADE FILL
#
# Build a dissolve clip of exactly XFADE seconds that transitions from IMG_A
# to IMG_B.  Uses ffmpeg xfade filter with transition=fade.
# Dissolves are short (XFADE << hold), so re-encoding each one is fine.
# ---------------------------------------------------------------------------
_slideshow_make_dissolve() {
  local img_a="$1" img_b="$2" out="$3" pw="$4" ph="$5" xfade="$6" fill="${7:-0}"
  local vf_scale; vf_scale="$(_slideshow_vf "$pw" "$ph" "$fill")"

  # Two normalized still inputs, xfade starting at offset=0; output = xfade seconds.
  "$FFMPEG" -nostdin -loglevel error -y \
    -loop 1 -framerate "$FPS" -t "$xfade" -i "$img_a" \
    -loop 1 -framerate "$FPS" -t "$xfade" -i "$img_b" \
    -filter_complex \
      "[0:v]${vf_scale}[va]; \
       [1:v]${vf_scale}[vb]; \
       [va][vb]xfade=transition=fade:duration=${xfade}:offset=0,format=yuv420p[vout]" \
    -map "[vout]" \
    -c:v libx264 -preset ultrafast -crf "$CRF" \
    -pix_fmt yuv420p \
    -an \
    "$out"
}

# ---------------------------------------------------------------------------
# xfade_join DIR EACH_HOURS OUT
#
# Main entry point for slideshow mode.
#
# Extra context (globals read by this function, set in make-video):
#   SLIDESHOW_XFADE   — dissolve duration in seconds (default 2.5)
#   SLIDESHOW_SHUFFLE — 1 = shuffle image order
#   SLIDESHOW_SEED    — seed for shuffle (default $$)
#   SLIDESHOW_FILL    — 1 = crop-to-fill; 0 = letterbox (default 0)
#   AUDIO_PATH        — optional soundtrack path (may be empty)
#   FPS               — frames per second (from make-video, default 30)
#   CRF               — quality (from make-video, default 18)
#   BASE_SECS         — encode-once base segment length (from make-video, default 30)
# ---------------------------------------------------------------------------
xfade_join() {
  local dir="$1"
  local each_hours="$2"
  local out="$3"

  [[ -d "$dir" ]] || { echo "xfade_join: not a directory: $dir" >&2; return 1; }

  # --- Read config globals (with safe defaults) ---
  local xfade="${SLIDESHOW_XFADE:-2.5}"
  local do_shuffle="${SLIDESHOW_SHUFFLE:-0}"
  local seed="${SLIDESHOW_SEED:-$$}"
  local fill="${SLIDESHOW_FILL:-0}"

  # --- Parse each_hours → each_secs (float via awk) ---
  local each_secs
  each_secs="$(awk -v h="$each_hours" 'BEGIN { printf "%.6f", h * 3600 }')"
  local each_secs_int
  each_secs_int="$(awk -v h="$each_hours" 'BEGIN { printf "%d", h * 3600 + 0.5 }')"
  [[ "$each_secs_int" -gt 0 ]] 2>/dev/null || { echo "xfade_join: each must be > 0" >&2; return 1; }

  # --- Validate --audio path early ---
  if [[ -n "${AUDIO_PATH:-}" ]]; then
    [[ -e "$AUDIO_PATH" ]] || { echo "xfade_join: --audio path not found: $AUDIO_PATH" >&2; return 1; }
  fi

  # --- Collect image files ---
  local -a img_files=()
  while IFS= read -r -d $'\0' f; do
    local base; base="$(basename "$f")"
    [[ "$base" == ._* ]] && continue
    [[ "$base" == .* ]] && continue
    is_image "$f" && img_files+=("$f")
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f -print0 | LC_ALL=C sort -z)

  local n="${#img_files[@]}"
  if [[ "$n" -eq 0 ]]; then
    echo "xfade_join: no image files found in: $dir" >&2
    return 1
  fi

  # --- Optional shuffle ---
  if [[ "$do_shuffle" -eq 1 ]]; then
    local shuffled
    shuffled="$(printf '%s\0' "${img_files[@]}" \
      | tr '\0' '\n' \
      | awk -v seed="$seed" 'BEGIN { srand(seed) } { print rand() "\t" $0 }' \
      | sort -t$'\t' -k1,1n \
      | cut -f2-)"
    local -a sorted_files=()
    while IFS= read -r line; do
      sorted_files+=("$line")
    done <<< "$shuffled"
    img_files=("${sorted_files[@]}")
  fi

  [[ "$n" -gt 100 ]] && printf '[slideshow] warning: %d images (large job)\n' "$n" >&2

  # --- Project resolution from first image ---
  local proj_dims
  proj_dims="$(img_dims "${img_files[0]}")" || {
    echo "xfade_join: could not read dimensions from: ${img_files[0]}" >&2
    return 1
  }
  local pw ph
  read -r pw ph <<< "$proj_dims"
  if [[ "$pw" -gt 3840 ]]; then
    ph=$(( ph * 3840 / pw ))
    pw=3840
    pw=$(( pw - pw % 2 ))
    ph=$(( ph - ph % 2 ))
  fi

  # --- Hold durations ---
  local hold_first hold_last hold_mid
  hold_first="$(awk -v e="$each_secs" -v x="$xfade" 'BEGIN { printf "%.6f", e - x }')"
  hold_last="$hold_first"

  local ok_first
  ok_first="$(awk -v h="$hold_first" 'BEGIN { print (h > 0.1) ? "ok" : "fail" }')"
  if [[ "$ok_first" != "ok" ]]; then
    printf 'xfade_join: per-image hold (%.2fs) is too short for xfade (%ss): first hold = %.2fs\n' \
      "$each_secs" "$xfade" "$hold_first" >&2
    return 1
  fi

  if [[ "$n" -gt 2 ]]; then
    hold_mid="$(awk -v e="$each_secs" -v x="$xfade" 'BEGIN { printf "%.6f", e - 2*x }')"
    local ok_mid
    ok_mid="$(awk -v h="$hold_mid" 'BEGIN { print (h > 0.1) ? "ok" : "fail" }')"
    if [[ "$ok_mid" != "ok" ]]; then
      printf 'xfade_join: interior hold (%.2fs) too short for xfade (%ss); need at least %.2fs each\n' \
        "$hold_mid" "$xfade" "$(awk -v x="$xfade" 'BEGIN { printf "%.2f", 2*x + 0.1 }')" >&2
      return 1
    fi
  fi

  # --- Total duration ---
  local total_secs
  total_secs="$(awk -v n="$n" -v e="$each_secs" -v x="$xfade" \
    'BEGIN { printf "%.6f", n*e - (n-1)*x }')"
  local total_secs_int
  total_secs_int="$(awk -v t="$total_secs" 'BEGIN { printf "%d", t + 0.5 }')"
  local est_mb
  est_mb="$(awk -v pw="$pw" -v ph="$ph" -v t="$total_secs" \
    'BEGIN { printf "%.0f", pw * ph * 3 * t / 1048576 / 10 }')"

  printf '[slideshow] %d image(s), each %.1fs, xfade %.1fs, total %.1fs (~%sMB est)\n' \
    "$n" "$each_secs" "$xfade" "$total_secs" "$est_mb"
  printf '[slideshow] resolution: %dx%d, fill=%d, shuffle=%d\n' \
    "$pw" "$ph" "$fill" "$do_shuffle"

  # --- Degenerate: single image ---
  if [[ "$n" -eq 1 ]]; then
    printf '[slideshow] single image: building static video (%ds)\n' "$each_secs_int"
    local tmp_dir; tmp_dir="$(mktemp -d)"
    _cleanup_slideshow_tmp() { rm -rf "$tmp_dir"; }

    if [[ -z "${AUDIO_PATH:-}" ]]; then
      _slideshow_build_hold "${img_files[0]}" "$out" "$pw" "$ph" "$fill" \
        "$each_secs" "$tmp_dir" \
        || { _cleanup_slideshow_tmp; return 1; }
    else
      local tmp_silent="$tmp_dir/silent.mp4"
      local tmp_audio="$tmp_dir/audio.aac"
      _slideshow_build_hold "${img_files[0]}" "$tmp_silent" "$pw" "$ph" "$fill" \
        "$each_secs" "$tmp_dir" \
        || { _cleanup_slideshow_tmp; return 1; }
      audio_build "$AUDIO_PATH" "$each_secs_int" "$tmp_audio" \
        || { _cleanup_slideshow_tmp; return 1; }
      mux_audio "$tmp_silent" "$tmp_audio" "$out" \
        || { _cleanup_slideshow_tmp; return 1; }
    fi
    _cleanup_slideshow_tmp
    return 0
  fi

  # --- Multi-image: holds + dissolves ---
  local tmp_dir; tmp_dir="$(mktemp -d)"
  _cleanup_slideshow_tmp() { rm -rf "$tmp_dir"; }

  # Build hold segments (encode-once + concat-copy per image)
  local -a hold_files=()
  local i
  for (( i=0; i<n; i++ )); do
    local hf="$tmp_dir/hold_${i}.mp4"
    local hold_dur
    if [[ "$i" -eq 0 ]]; then
      hold_dur="$hold_first"
    elif [[ "$i" -eq $(( n - 1 )) ]]; then
      hold_dur="$hold_last"
    else
      hold_dur="$hold_mid"
    fi
    _slideshow_build_hold "${img_files[$i]}" "$hf" "$pw" "$ph" "$fill" \
      "$hold_dur" "$tmp_dir" \
      || { _cleanup_slideshow_tmp; return 1; }
    hold_files+=("$hf")
  done

  # Build dissolve clips (re-encode; short by definition = xfade seconds each)
  local -a dissolve_files=()
  for (( i=0; i<n-1; i++ )); do
    local df="$tmp_dir/dissolve_${i}.mp4"
    _slideshow_make_dissolve \
      "${img_files[$i]}" "${img_files[$((i+1))]}" \
      "$df" "$pw" "$ph" "$xfade" "$fill" \
      || { _cleanup_slideshow_tmp; return 1; }
    dissolve_files+=("$df")
  done

  # Concat list: hold_0, d_0, hold_1, d_1, ..., hold_{n-1}
  local list_file="$tmp_dir/concat.txt"
  : > "$list_file"
  for (( i=0; i<n; i++ )); do
    printf "file '%s'\n" "${hold_files[$i]}" >> "$list_file"
    if [[ "$i" -lt $(( n - 1 )) ]]; then
      printf "file '%s'\n" "${dissolve_files[$i]}" >> "$list_file"
    fi
  done

  # Concat-copy to final output (or to silent temp if audio is requested)
  if [[ -z "${AUDIO_PATH:-}" ]]; then
    "$FFMPEG" -nostdin -loglevel error -y \
      -f concat -safe 0 -i "$list_file" \
      -c copy \
      -movflags +faststart \
      "$out" || { _cleanup_slideshow_tmp; return 1; }
  else
    local tmp_silent="$tmp_dir/silent.mp4"
    local tmp_audio="$tmp_dir/audio.aac"
    "$FFMPEG" -nostdin -loglevel error -y \
      -f concat -safe 0 -i "$list_file" \
      -c copy \
      -movflags +faststart \
      "$tmp_silent" || { _cleanup_slideshow_tmp; return 1; }
    audio_build "$AUDIO_PATH" "$total_secs_int" "$tmp_audio" \
      || { _cleanup_slideshow_tmp; return 1; }
    mux_audio "$tmp_silent" "$tmp_audio" "$out" \
      || { _cleanup_slideshow_tmp; return 1; }
  fi

  _cleanup_slideshow_tmp

  printf '[slideshow] VERIFY: expected %.1fs, actual: ' "$total_secs"
  "$FFPROBE" -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$out" | awk '{ printf "%.1f", $1 }'; printf 's\n'

  printf '✓ slideshow  (%d images, %.1fs each, xfade %.1fs, total %.1fs)  ->  %s\n' \
    "$n" "$each_secs" "$xfade" "$total_secs" "$out"
}
