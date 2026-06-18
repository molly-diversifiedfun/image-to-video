#!/usr/bin/env bats
#
# clip_sequencer.bats — unit tests for lib/sequencer.sh::sequence_clips (PRD-4)
#
# Contract:
#   sequence_clips TARGET_SECS XFADE SEED MODE  < (path<TAB>dur lines on stdin)
#     → prints the ordered clip paths (one per line, repeats allowed) that fill
#       the timeline to >= TARGET_SECS, where:
#         timeline(count) = Σ dur_i − (count−1)·XFADE
#       MODE = shuffle (default): each pass is a fresh seeded permutation of the
#              clips, no clip adjacent to itself, reshuffled every pass.
#       MODE = name: identity order, cycled (deterministic, no shuffle).
#   SEED makes shuffle reproducible. Pure logic — no ffmpeg.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

bats_require_minimum_version 1.5.0

setup() {
  source "$REPO_ROOT/lib/sequencer.sh"
}

# Feed N clips named clipNN with a uniform duration on stdin.
# usage: feed_clips DUR N
feed_clips() {
  local dur="$1" n="$2" i
  for (( i=1; i<=n; i++ )); do
    printf 'clip%02d\t%s\n' "$i" "$dur"
  done
}

# timeline(count, dur, xfade) = count*dur - (count-1)*xfade   (uniform dur)
# ---------------------------------------------------------------------------

# T1 — name mode fills to target deterministically by cycling input order.
@test "name mode cycles input order and fills to target" {
  # 3 clips × 10s, xfade 0, target 25 → A(10) B(20) C(30>=25) → A B C
  run bash -c "source '$REPO_ROOT/lib/sequencer.sh'; \
    { printf 'A\t10\n'; printf 'B\t10\n'; printf 'C\t10\n'; } | sequence_clips 25 0 1 name"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "A" ]
  [ "${lines[1]}" = "B" ]
  [ "${lines[2]}" = "C" ]
  [ "${#lines[@]}" -eq 3 ]
}

# T2 — same seed reproduces an identical shuffle order.
@test "shuffle with same seed is reproducible" {
  local a b
  a="$(feed_clips 10 5 | sequence_clips 200 0 7 shuffle)"
  b="$(feed_clips 10 5 | sequence_clips 200 0 7 shuffle)"
  [ "$a" = "$b" ]
}

# T3 — no clip is ever adjacent to itself (the headline acceptance criterion).
@test "shuffle never places a clip back-to-back with itself" {
  local out prev=""
  out="$(feed_clips 10 4 | sequence_clips 500 0 3 shuffle)"
  while IFS= read -r line; do
    [ "$line" != "$prev" ] || { echo "adjacent repeat: $line"; return 1; }
    prev="$line"
  done <<< "$out"
}

# T4 — minimal fill: timeline reaches target, dropping the last clip undershoots.
@test "fills to target with no surplus clip" {
  # 10s clips, xfade 0, target 35 → 4 clips (40>=35); 3 clips (30<35) too few.
  local out count
  out="$(feed_clips 10 6 | sequence_clips 35 0 9 shuffle)"
  count="$(printf '%s\n' "$out" | grep -c .)"
  [ "$count" -eq 4 ]
}

# T5 — each full pass is a permutation of all clips (even exposure, reshuffle).
@test "each pass is a permutation of the full clip set" {
  # 4 clips, target spans 2+ passes. First 4 and next 4 must each be all distinct.
  local out
  out="$(feed_clips 10 4 | sequence_clips 1000 0 11 shuffle)"
  local first4 next4
  first4="$(printf '%s\n' "$out" | sed -n '1,4p' | sort -u | grep -c .)"
  next4="$(printf '%s\n' "$out"  | sed -n '5,8p' | sort -u | grep -c .)"
  [ "$first4" -eq 4 ]
  [ "$next4" -eq 4 ]
}

# T6 — different seeds generally produce different orders.
@test "different seeds produce different orders" {
  local a b
  a="$(feed_clips 10 6 | sequence_clips 400 0 1 shuffle)"
  b="$(feed_clips 10 6 | sequence_clips 400 0 2 shuffle)"
  [ "$a" != "$b" ]
}

# T7 — xfade overlap is accounted for in the fill (more clips needed).
@test "xfade overlap increases the clip count needed to fill" {
  # 10s clips, xfade 2, target 35:
  #   timeline(n) = 10n - 2(n-1) = 8n + 2.  n=4 → 34 (<35), n=5 → 42 (>=35) → 5
  local out count
  out="$(feed_clips 10 8 | sequence_clips 35 2 5 name)"
  count="$(printf '%s\n' "$out" | grep -c .)"
  [ "$count" -eq 5 ]
}

# T8 — single clip: repeats to fill (no adjacent-repeat constraint is possible).
@test "single clip repeats to fill the target" {
  local out count
  out="$(printf 'solo\t10\n' | sequence_clips 25 0 1 shuffle)"
  count="$(printf '%s\n' "$out" | grep -c .)"
  [ "$count" -eq 3 ]            # 10,20,30 >= 25
  [ "$(printf '%s\n' "$out" | sort -u | grep -c .)" -eq 1 ]   # all 'solo'
}

# T9 — empty input is an error.
@test "empty clip list fails" {
  run bash -c "source '$REPO_ROOT/lib/sequencer.sh'; printf '' | sequence_clips 10 0 1 shuffle"
  [ "$status" -ne 0 ]
}
