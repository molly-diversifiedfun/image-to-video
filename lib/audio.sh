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
  # Directory SRC — stub; future folder/playlist branch goes here
  # ------------------------------------------------------------------
  if [[ -d "$src" ]]; then
    echo "audio_build: directory SRC not yet implemented (stub returns 2)" >&2
    return 2
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
