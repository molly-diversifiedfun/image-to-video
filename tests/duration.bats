#!/usr/bin/env bats
#
# duration.bats — tests for lib/duration.sh :: parse_duration HOURS
#
# Contract:
#   - Echoes integer seconds = round(HOURS * 3600)
#   - Uses awk printf "%d", h*3600 + 0.5  (round-half-up)
#   - If HOURS is not a positive number (<=0, empty, non-numeric) →
#       print error to stderr AND return non-zero

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# --separate-stderr requires bats 1.5+
bats_require_minimum_version 1.5.0

setup() {
  source "$REPO_ROOT/lib/duration.sh"
}

# ---------------------------------------------------------------------------
# Happy-path: integer and fractional hours
# ---------------------------------------------------------------------------

@test "parse_duration: 3 hours → 10800 seconds" {
  run parse_duration 3
  [ "$status" -eq 0 ]
  [ "$output" = "10800" ]
}

@test "parse_duration: 0.5 hours → 1800 seconds" {
  run parse_duration 0.5
  [ "$status" -eq 0 ]
  [ "$output" = "1800" ]
}

@test "parse_duration: 0.0167 hours → 60 seconds (rounds up, not 59)" {
  # 0.0167 * 3600 = 60.12 → round → 60
  run parse_duration 0.0167
  [ "$status" -eq 0 ]
  [ "$output" = "60" ]
}

@test "parse_duration: 2.5 hours → 9000 seconds" {
  run parse_duration 2.5
  [ "$status" -eq 0 ]
  [ "$output" = "9000" ]
}

# ---------------------------------------------------------------------------
# Edge cases: 0, negative, non-numeric, empty → non-zero + stderr
# ---------------------------------------------------------------------------

@test "parse_duration: 0 → non-zero exit status" {
  run parse_duration 0
  [ "$status" -ne 0 ]
}

@test "parse_duration: -1 → non-zero exit status" {
  run parse_duration -1
  [ "$status" -ne 0 ]
}

@test "parse_duration: abc (non-numeric) → non-zero exit status" {
  run parse_duration abc
  [ "$status" -ne 0 ]
}

@test "parse_duration: empty string → non-zero exit status" {
  run parse_duration ""
  [ "$status" -ne 0 ]
}

@test "parse_duration: error message goes to stderr, stdout is empty" {
  # --separate-stderr (bats 1.5+): $output = stdout only, $stderr = stderr only
  run --separate-stderr parse_duration 0
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Additional edge cases: malformed numbers → non-zero
# ---------------------------------------------------------------------------

@test "parse_duration: 1.2.3 (double-dot) → non-zero exit status" {
  run parse_duration "1.2.3"
  [ "$status" -ne 0 ]
}

@test "parse_duration: 1e3 (scientific notation) → non-zero exit status" {
  run parse_duration "1e3"
  [ "$status" -ne 0 ]
}

@test "parse_duration: +5 (leading plus) → non-zero exit status" {
  run parse_duration "+5"
  [ "$status" -ne 0 ]
}

@test "parse_duration: space-padded ' 3 ' → non-zero exit status" {
  run parse_duration " 3 "
  [ "$status" -ne 0 ]
}

@test "parse_duration: .5 (leading dot, no leading zero) → non-zero exit status" {
  run parse_duration ".5"
  [ "$status" -ne 0 ]
}
