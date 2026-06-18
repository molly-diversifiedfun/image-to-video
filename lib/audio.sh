#!/usr/bin/env bash
#
# lib/audio.sh — audio_build SRC TARGET_SECS OUT
#
# Build an audio file of EXACTLY TARGET_SECS seconds (AAC, 192k) from SRC.
#
# SRC >= TARGET_SECS:
#   Trim to TARGET_SECS.  Apply a 0.5s fade-out at the end so it doesn't cut
#   abruptly.  Loudness-normalise the result to EBU R128 (I=-16, TP=-1.5,
#   LRA=11).
#
# SRC < TARGET_SECS:
#   Build a seamless-loop unit:
#     body  = SRC trimmed to (SRC_DUR - SEAM)
#     seam  = last SEAM seconds of SRC crossfaded (acrossfade, tri window) with
#             first SEAM seconds of SRC — this removes the amplitude
#             discontinuity at the wrap boundary
#     unit  = body + seam  (≈ SRC_DUR seconds, loopable)
#   Tile that unit with aloop until the tiled stream exceeds TARGET_SECS.
#   atrim to exactly TARGET_SECS.
#   Apply loudnorm.
#
# Directory SRC:
#   Returns 2.  Stub for a future folder/playlist branch.
#   Dispatch in caller: [[ -d "$SRC" ]] → future implementation.
#
# Validation:
#   • SRC must exist (file or dir check before dir-branch dispatch)
#   • TARGET_SECS must be a positive integer (regex [1-9][0-9]*)
#
# Output: AAC, -b:a 192k, -nostdin -loglevel error -y.
#
# Dependencies:
#   $FFMPEG and $FFPROBE must be set by the caller (fixtures.sh or make-video).
#   bash 3.2+; uses awk, not bc.

# ---------------------------------------------------------------------------
# _audio_get_duration FILE
# Internal helper: echo the float duration (seconds) of FILE via ffprobe.
# Returns 1 if ffprobe can't read it.
# ---------------------------------------------------------------------------
_audio_get_duration() {
  local file="$1"
  local dur
  dur="$("$FFPROBE" \
    -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file")"
  [[ "$dur" =~ ^[0-9] ]] || return 1
  echo "$dur"
}

# ---------------------------------------------------------------------------
# _audio_collect_files DIR
# Internal: emit the sorted list of audio filenames (basename only, one per line)
# from DIR.  Skips dotfiles, ._* macOS resource forks, and non-audio extensions.
# Audio extensions: mp3 m4a aac wav flac ogg opus
# Returns 1 (and emits nothing) if no audio files are found.
# ---------------------------------------------------------------------------
_audio_collect_files() {
  local dir="$1"
  local found=0
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    local base
    base="$(basename "$f")"
    # Skip dotfiles and macOS resource-fork prefixed files
    [[ "$base" == .* ]] && continue
    # Match supported audio extensions (case-insensitive; bash 3.2 compatible)
    local ext
    ext="$(echo "${base##*.}" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
      mp3|m4a|aac|wav|flac|ogg|opus)
        echo "$base"
        found=1
        ;;
    esac
  done
  return $(( 1 - found ))
}

# ---------------------------------------------------------------------------
# _audio_shuffle_lines SEED
# Internal: read lines from stdin, shuffle deterministically using SEED.
# Uses awk's PRNG seeded with SEED to assign a sort key per line, then sort.
# Same SEED always produces the same permutation.
# ---------------------------------------------------------------------------
_audio_shuffle_lines() {
  local seed="${1:-$$}"
  awk -v seed="$seed" 'BEGIN { srand(seed) } { print rand() "\t" $0 }' \
    | sort -t$'\t' -k1,1n \
    | cut -f2-
}

# ---------------------------------------------------------------------------
# _audio_build_playlist DIR TARGET_SECS OUT [--shuffle] [--seed N]
#
# Build a TARGET_SECS (AAC, 192k) seamless playlist from the audio files in DIR.
#
# Algorithm:
#   1. Collect audio files (sorted by name by default; --shuffle randomises).
#   2. Loudness-normalise each track to I=-16 (per-track, so no loudness jump).
#   3. Join tracks with acrossfade (1.0s default) for click-free transitions.
#   4. Loop the joined playlist (also crossfaded at the wrap) to fill TARGET_SECS.
#   5. Trim to EXACTLY TARGET_SECS, encode AAC 192k.
# ---------------------------------------------------------------------------
_audio_build_playlist() {
  local dir="${1:?_audio_build_playlist: DIR required}"
  local target_secs="${2:?_audio_build_playlist: TARGET_SECS required}"
  local out="${3:?_audio_build_playlist: OUT required}"
  shift 3

  local do_shuffle=0
  local seed=""

  # Parse optional trailing args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shuffle) do_shuffle=1; shift ;;
      --seed)
        seed="${2:?--seed requires a value}"
        do_shuffle=1
        shift 2
        ;;
      *) echo "_audio_build_playlist: unknown option: $1" >&2; return 1 ;;
    esac
  done

  # ------------------------------------------------------------------
  # 1. Collect audio files
  # ------------------------------------------------------------------
  local file_list
  file_list="$(_audio_collect_files "$dir")"
  if [[ -z "$file_list" ]]; then
    echo "audio_build: no audio files found in directory: ${dir}" >&2
    return 1
  fi

  # Sort by filename (default) then optionally shuffle
  local ordered_files
  ordered_files="$(echo "$file_list" | sort)"

  if [[ "$do_shuffle" -eq 1 ]]; then
    local effective_seed="${seed:-$$}"
    ordered_files="$(echo "$ordered_files" | _audio_shuffle_lines "$effective_seed")"
  fi

  # Build absolute path array
  local files=()
  while IFS= read -r name; do
    files+=("$dir/$name")
  done <<< "$ordered_files"

  local num_files="${#files[@]}"

  # ------------------------------------------------------------------
  # 2. Loudness-normalise each track to I=-16 → temp PCM files
  # ------------------------------------------------------------------
  local norm_dir
  norm_dir="$(mktemp -d)"

  local norm_files=()
  local i
  for (( i=0; i<num_files; i++ )); do
    local nf="${norm_dir}/norm_${i}.wav"
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "${files[$i]}" \
      -filter_complex "[0:a]loudnorm=I=-16:TP=-1.5:LRA=11[out]" \
      -map "[out]" \
      -c:a pcm_s16le \
      "$nf" || {
        echo "audio_build: failed to normalise track: ${files[$i]}" >&2
        rm -rf "$norm_dir"
        return 1
      }
    norm_files+=("$nf")
  done

  # ------------------------------------------------------------------
  # 3. Join all normalised tracks with acrossfade
  # The crossfade duration is 1.0s, clamped so it never exceeds
  # half the shortest track.
  # ------------------------------------------------------------------
  local xfade_d="1.0"

  # Find minimum track duration to clamp xfade
  local min_dur="999999"
  for nf in "${norm_files[@]}"; do
    local d
    d="$(_audio_get_duration "$nf")" || continue
    min_dur="$(awk -v a="$min_dur" -v b="$d" 'BEGIN { print (a < b) ? a : b }')"
  done

  # Clamp xfade_d to at most half of min_dur
  xfade_d="$(awk -v x="$xfade_d" -v m="$min_dur" 'BEGIN {
    half = m / 2.0
    print (x < half) ? x : half * 0.9
  }')"

  # Build a single joined PCM from all normalised tracks
  local joined_wav="${norm_dir}/joined.wav"

  if [[ "$num_files" -eq 1 ]]; then
    # Only one track — no crossfade needed, just copy
    cp "${norm_files[0]}" "$joined_wav"
  else
    # Build an ffmpeg filter that acrossfades all tracks sequentially.
    # Each acrossfade consumes the end of [prev] and start of [next].
    # Label progression: [0:a] acrossfade [1:a] → [cf0], [cf0] acrossfade [2:a] → [cf1], …
    local inputs=()
    local fc=""
    for nf in "${norm_files[@]}"; do
      inputs+=(-i "$nf")
    done

    # Build filter_complex string step by step
    if [[ "$num_files" -eq 2 ]]; then
      fc="[0:a][1:a]acrossfade=d=${xfade_d}:c1=tri:c2=tri[out]"
    else
      # Chain: first pair produces [cf0], then each subsequent input is faded in
      fc="[0:a][1:a]acrossfade=d=${xfade_d}:c1=tri:c2=tri[cf0];"
      for (( i=2; i<num_files; i++ )); do
        local prev_label="cf$(( i - 2 ))"
        local this_label
        if [[ "$i" -eq $(( num_files - 1 )) ]]; then
          this_label="out"
        else
          this_label="cf$(( i - 1 ))"
        fi
        fc="${fc}[${prev_label}][${i}:a]acrossfade=d=${xfade_d}:c1=tri:c2=tri[${this_label}];"
      done
      # Remove trailing semicolon
      fc="${fc%;}"
    fi

    "$FFMPEG" \
      -nostdin -loglevel error -y \
      "${inputs[@]}" \
      -filter_complex "$fc" \
      -map "[out]" \
      -c:a pcm_s16le \
      "$joined_wav" || {
        echo "audio_build: failed to join tracks" >&2
        rm -rf "$norm_dir"
        return 1
      }
  fi

  # ------------------------------------------------------------------
  # 4. Loop the joined playlist to fill TARGET_SECS (reuse loop-path
  #    logic from the single-file branch: build a seamless unit, aloop,
  #    atrim, loudnorm, encode AAC).
  # ------------------------------------------------------------------
  local joined_dur
  joined_dur="$(_audio_get_duration "$joined_wav")" || {
    echo "audio_build: could not read joined duration" >&2
    rm -rf "$norm_dir"
    return 1
  }

  local needs_loop
  needs_loop="$(awk -v d="$joined_dur" -v t="$target_secs" \
    'BEGIN { print (d < t) ? "1" : "0" }')"

  if [[ "$needs_loop" == "0" ]]; then
    # Joined playlist is already >= target — just trim + final loudnorm + encode
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$joined_wav" \
      -filter_complex "
        [0:a]atrim=end=${target_secs},asetpts=PTS-STARTPTS,
        loudnorm=I=-16:TP=-1.5:LRA=11[out]
      " \
      -map "[out]" \
      -c:a aac \
      -b:a 192k \
      "$out"
    local st=$?
    rm -rf "$norm_dir"
    return $st
  fi

  # Need to loop: build a seamless loop unit from the joined playlist
  # (crossfade the end of joined back to its start, same pattern as single-file loop).
  local seam="$xfade_d"

  # Clamp seam to at most half of joined_dur
  seam="$(awk -v s="$seam" -v d="$joined_dur" 'BEGIN {
    half = d / 2.0
    print (s < half) ? s : half * 0.9
  }')"

  local tail_start
  tail_start="$(awk -v d="$joined_dur" -v s="$seam" \
    'BEGIN { printf "%.6f", d - s }')"

  # Build seamless loop unit as PCM
  local unit_wav="${norm_dir}/unit.wav"
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -i "$joined_wav" \
    -i "$joined_wav" \
    -filter_complex "
      [0:a]atrim=start=${tail_start},asetpts=PTS-STARTPTS[tail];
      [1:a]atrim=end=${seam},asetpts=PTS-STARTPTS[head];
      [tail][head]acrossfade=d=${seam}:c1=tri:c2=tri[seampart];
      [0:a]atrim=end=${tail_start},asetpts=PTS-STARTPTS[body];
      [body][seampart]concat=n=2:v=0:a=1[unit]
    " \
    -map "[unit]" \
    -c:a pcm_s16le \
    "$unit_wav" || {
      echo "audio_build: failed to build playlist loop unit" >&2
      rm -rf "$norm_dir"
      return 1
    }

  # Get unit sample count (rate-aware, same as single-file branch)
  local unit_dur unit_sr unit_samps
  unit_dur="$(_audio_get_duration "$unit_wav")" || {
    echo "audio_build: could not read unit duration" >&2
    rm -rf "$norm_dir"
    return 1
  }

  unit_sr="$("$FFPROBE" \
    -v error \
    -select_streams a:0 \
    -show_entries stream=sample_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$unit_wav")"
  [[ "$unit_sr" =~ ^[0-9]+$ ]] || unit_sr=44100

  unit_samps="$(awk -v d="$unit_dur" -v sr="$unit_sr" \
    'BEGIN { printf "%d", d * sr + 0.5 }')"

  local loops
  loops="$(awk -v t="$target_secs" -v u="$unit_dur" \
    'BEGIN { printf "%d", int(t / u) + 2 }')"

  # Tile, trim, final loudnorm, encode
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -i "$unit_wav" \
    -filter_complex "
      [0:a]aloop=loop=${loops}:size=${unit_samps},
      atrim=end=${target_secs},
      asetpts=PTS-STARTPTS,
      loudnorm=I=-16:TP=-1.5:LRA=11[out]
    " \
    -map "[out]" \
    -c:a aac \
    -b:a 192k \
    "$out"
  local st=$?
  rm -rf "$norm_dir"
  return $st
}

# ---------------------------------------------------------------------------
# audio_build SRC TARGET_SECS OUT
# ---------------------------------------------------------------------------
audio_build() {
  local src="${1:?audio_build: SRC required}"
  local target_secs="${2:?audio_build: TARGET_SECS required}"
  local out="${3:?audio_build: OUT required}"

  # ------------------------------------------------------------------
  # Validate TARGET_SECS: must be a positive integer (no floats, no negatives)
  # ------------------------------------------------------------------
  if [[ ! "$target_secs" =~ ^[1-9][0-9]*$ ]]; then
    echo "audio_build: TARGET_SECS must be a positive integer, got: '${target_secs}'" >&2
    return 1
  fi

  # ------------------------------------------------------------------
  # Validate SRC exists
  # ------------------------------------------------------------------
  if [[ ! -e "$src" ]]; then
    echo "audio_build: SRC not found: ${src}" >&2
    return 1
  fi

  # ------------------------------------------------------------------
  # Directory SRC — folder/playlist branch
  # ------------------------------------------------------------------
  if [[ -d "$src" ]]; then
    _audio_build_playlist "$src" "$target_secs" "$out" "${@:4}"
    return $?
  fi

  # ------------------------------------------------------------------
  # Get SRC duration
  # ------------------------------------------------------------------
  local src_dur
  if ! src_dur="$(_audio_get_duration "$src")"; then
    echo "audio_build: could not read duration from SRC: ${src}" >&2
    return 1
  fi

  # ------------------------------------------------------------------
  # Decide: trim path vs loop path
  # ------------------------------------------------------------------
  local is_long
  is_long="$(awk -v d="$src_dur" -v t="$target_secs" \
    'BEGIN { print (d >= t) ? "1" : "0" }')"

  if [[ "$is_long" == "1" ]]; then
    # ----------------------------------------------------------------
    # TRIM PATH: SRC_DUR >= TARGET_SECS
    # Trim to TARGET_SECS, add 0.5s fade-out, loudnorm.
    # ----------------------------------------------------------------
    local fade_start
    fade_start="$(awk -v t="$target_secs" 'BEGIN { printf "%.3f", t - 0.5 }')"

    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$src" \
      -filter_complex "
        [0:a]atrim=end=${target_secs},asetpts=PTS-STARTPTS,
        afade=t=out:st=${fade_start}:d=0.5,
        loudnorm=I=-16:TP=-1.5:LRA=11[out]
      " \
      -map "[out]" \
      -c:a aac \
      -b:a 192k \
      "$out"
  else
    # ----------------------------------------------------------------
    # LOOP PATH: SRC_DUR < TARGET_SECS
    #
    # Build a seamless loop unit:
    #   tail  = last SEAM seconds of SRC
    #   head  = first SEAM seconds of SRC
    #   seam  = acrossfade(tail, head, d=SEAM)  ← click-free wrap
    #   body  = SRC[0 .. SRC_DUR-SEAM)
    #   unit  = concat(body, seam)               ← ≈ SRC_DUR seconds, loopable
    #
    # Tile with aloop, trim to TARGET_SECS, loudnorm.
    # ----------------------------------------------------------------
    local seam="0.5"

    # Clamp seam to at most half of src_dur so it's always positive
    seam="$(awk -v s="$seam" -v d="$src_dur" 'BEGIN {
      half = d / 2.0
      print (s < half) ? s : half * 0.9
    }')"

    local tail_start
    tail_start="$(awk -v d="$src_dur" -v s="$seam" \
      'BEGIN { printf "%.6f", d - s }')"

    # Step 1: build the seamless unit as PCM in a temp file so we can
    # measure its exact sample count for aloop's size= parameter.
    local unit_wav
    unit_wav="$(mktemp -p "$WORK_DIR" 2>/dev/null || mktemp)"
    # Ensure the temp file ends with .wav for ffmpeg format detection.
    # On cross-device temp dirs mv fails; clean up the original before reassigning
    # to avoid leaking a stale file without the .wav suffix.
    local unit_wav_path="${unit_wav}.wav"
    mv "$unit_wav" "$unit_wav_path" 2>/dev/null || { unit_wav_path="${unit_wav}.wav"; rm -f "$unit_wav"; }

    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$src" \
      -i "$src" \
      -filter_complex "
        [0:a]atrim=start=${tail_start},asetpts=PTS-STARTPTS[tail];
        [1:a]atrim=end=${seam},asetpts=PTS-STARTPTS[head];
        [tail][head]acrossfade=d=${seam}:c1=tri:c2=tri[seampart];
        [0:a]atrim=end=${tail_start},asetpts=PTS-STARTPTS[body];
        [body][seampart]concat=n=2:v=0:a=1[unit]
      " \
      -map "[unit]" \
      -c:a pcm_s16le \
      "$unit_wav_path" || {
        rm -f "$unit_wav_path"
        echo "audio_build: failed to build loop unit" >&2
        return 1
      }

    # Step 2: get exact sample count of the unit (PCM: exact by construction).
    # We derive sample count as duration * actual_sample_rate so the calculation
    # is correct for any source sample rate (44100, 48000, etc.).  Using a
    # hardcoded 44100 would misplace the aloop boundary for 48 kHz sources,
    # causing the loop to cut in the middle of the crossfade and produce a click.
    local unit_dur
    unit_dur="$(_audio_get_duration "$unit_wav_path")" || {
      rm -f "$unit_wav_path"
      echo "audio_build: could not read unit duration" >&2
      return 1
    }

    local unit_sr
    unit_sr="$("$FFPROBE" \
      -v error \
      -select_streams a:0 \
      -show_entries stream=sample_rate \
      -of default=noprint_wrappers=1:nokey=1 \
      "$unit_wav_path")"
    # Fall back to 44100 only if ffprobe can't read the sample rate (shouldn't happen for PCM)
    [[ "$unit_sr" =~ ^[0-9]+$ ]] || unit_sr=44100

    local unit_samps
    unit_samps="$(awk -v d="$unit_dur" -v sr="$unit_sr" \
      'BEGIN { printf "%d", d * sr + 0.5 }')"

    # Step 3: compute loop count — enough to exceed TARGET_SECS
    local loops
    loops="$(awk -v t="$target_secs" -v u="$unit_dur" \
      'BEGIN { printf "%d", int(t / u) + 2 }')"

    # Step 4: tile, trim, loudnorm, encode to AAC
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$unit_wav_path" \
      -filter_complex "
        [0:a]aloop=loop=${loops}:size=${unit_samps},
        atrim=end=${target_secs},
        asetpts=PTS-STARTPTS,
        loudnorm=I=-16:TP=-1.5:LRA=11[out]
      " \
      -map "[out]" \
      -c:a aac \
      -b:a 192k \
      "$out"

    local ffmpeg_status=$?
    rm -f "$unit_wav_path"
    return $ffmpeg_status
  fi
}
