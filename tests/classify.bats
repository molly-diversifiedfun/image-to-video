#!/usr/bin/env bats
#
# classify.bats — tests for lib/classify.sh :: classify_input PATH
#
# Contract:
#   - Echoes exactly one of: image, video, image-dir, video-dir, unknown
#   - Returns 0 for any path that exists (even if classification is unknown)
#   - Returns non-zero if PATH does not exist

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  source "$REPO_ROOT/lib/classify.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# Single-file tests
# ---------------------------------------------------------------------------

@test "classify_input: single png image → image" {
  mk_image "$WORK_DIR/frame.png" blue
  run classify_input "$WORK_DIR/frame.png"
  [ "$status" -eq 0 ]
  [ "$output" = "image" ]
}

@test "classify_input: single mp4 clip → video" {
  mk_clip "$WORK_DIR/clip.mp4"
  run classify_input "$WORK_DIR/clip.mp4"
  [ "$status" -eq 0 ]
  [ "$output" = "video" ]
}

@test "classify_input: uppercase extension .JPG → image (case-insensitive)" {
  # mk_image writes whatever extension we give; rename to uppercase
  mk_image "$WORK_DIR/frame.png" red
  cp "$WORK_DIR/frame.png" "$WORK_DIR/PHOTO.JPG"
  run classify_input "$WORK_DIR/PHOTO.JPG"
  [ "$status" -eq 0 ]
  [ "$output" = "image" ]
}

@test "classify_input: non-media file (.txt) → unknown" {
  local txt="$WORK_DIR/notes.txt"
  printf "hello\n" > "$txt"
  run classify_input "$txt"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ---------------------------------------------------------------------------
# Directory tests
# ---------------------------------------------------------------------------

@test "classify_input: directory of images → image-dir" {
  local dir="$WORK_DIR/images"
  mkdir -p "$dir"
  mk_image "$dir/a.png" red
  mk_image "$dir/b.png" green
  run classify_input "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "image-dir" ]
}

@test "classify_input: directory of images with AppleDouble junk files → image-dir (junk ignored)" {
  local dir="$WORK_DIR/images_with_junk"
  mkdir -p "$dir"
  mk_image "$dir/a.png" blue
  # Simulate macOS AppleDouble resource-fork sidecar and hidden dotfile
  printf "junk\n" > "$dir/._a.png"
  printf "junk\n" > "$dir/.DS_Store"
  run classify_input "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "image-dir" ]
}

@test "classify_input: directory of video clips → video-dir" {
  local dir="$WORK_DIR/clips"
  mkdir -p "$dir"
  mk_clip "$dir/a.mp4"
  mk_clip "$dir/b.mp4"
  run classify_input "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "video-dir" ]
}

@test "classify_input: directory containing only a .txt file → unknown" {
  local dir="$WORK_DIR/textonly"
  mkdir -p "$dir"
  printf "hello\n" > "$dir/readme.txt"
  run classify_input "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ---------------------------------------------------------------------------
# Non-existent path → non-zero return
# ---------------------------------------------------------------------------

@test "classify_input: nonexistent path → non-zero exit status" {
  run classify_input "$WORK_DIR/does_not_exist.png"
  [ "$status" -ne 0 ]
}
