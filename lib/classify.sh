#!/usr/bin/env bash
#
# lib/classify.sh — classify_input PATH
#
# Echoes exactly one of: image, video, image-dir, video-dir, unknown
# Returns 0 for any path that exists; non-zero if PATH does not exist.
#
# Image extensions : jpg jpeg png tif tiff bmp webp heic gif
# Video extensions : mp4 mov m4v avi mkv webm
# Extension matching is case-insensitive.
#
# Directory rules:
#   - Dotfiles (.*) and macOS AppleDouble sidecar files (._*) are skipped.
#   - The first media file found (sorted) determines the classification.
#   - If no media file exists in the directory, echoes unknown.
#
# Requires: bash 3.2+, awk (no bc, no external deps beyond coreutils)

# ---------------------------------------------------------------------------
# _classify_ext EXT
#
# Internal helper: echoes "image", "video", or "" for a lowercased extension.
# ---------------------------------------------------------------------------
_classify_ext() {
  local ext="$1"
  case "$ext" in
    jpg|jpeg|png|tif|tiff|bmp|webp|heic|gif)
      echo "image" ;;
    mp4|mov|m4v|avi|mkv|webm)
      echo "video" ;;
    *)
      echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# classify_input PATH
# ---------------------------------------------------------------------------
classify_input() {
  local path="${1:?classify_input: PATH required}"

  # Non-existent path → non-zero return (no output)
  if [[ ! -e "$path" ]]; then
    return 1
  fi

  # --- File ---
  if [[ -f "$path" ]]; then
    # Extract extension: everything after the last dot, lowercased
    local basename="${path##*/}"
    local ext="${basename##*.}"
    # If there's no dot, ext == basename (no extension)
    [[ "$ext" == "$basename" ]] && ext=""
    # Lowercase via awk (bash 3.2-safe; ${var,,} requires bash 4+)
    ext="$(printf '%s' "$ext" | awk '{ print tolower($0) }')"
    local kind
    kind="$(_classify_ext "$ext")"
    if [[ -n "$kind" ]]; then
      echo "$kind"
    else
      echo "unknown"
    fi
    return 0
  fi

  # --- Directory ---
  if [[ -d "$path" ]]; then
    # Iterate sorted filenames, skipping dotfiles and ._* AppleDouble files
    local first_kind=""
    while IFS= read -r -d '' entry; do
      local fname="${entry##*/}"
      # Skip dotfiles (includes ._* AppleDouble sidecars and .DS_Store)
      [[ "$fname" == .* ]] && continue
      # Only classify regular files
      [[ -f "$entry" ]] || continue
      local ext="${fname##*.}"
      [[ "$ext" == "$fname" ]] && ext=""
      ext="$(printf '%s' "$ext" | awk '{ print tolower($0) }')"
      local kind
      kind="$(_classify_ext "$ext")"
      if [[ -n "$kind" ]]; then
        first_kind="$kind"
        break
      fi
    done < <(find "$path" -maxdepth 1 -mindepth 1 -print0 | sort -z)

    if [[ "$first_kind" == "image" ]]; then
      echo "image-dir"
    elif [[ "$first_kind" == "video" ]]; then
      echo "video-dir"
    else
      echo "unknown"
    fi
    return 0
  fi

  # Anything else (symlink to nonexistent, special file, etc.)
  echo "unknown"
  return 0
}
