#!/usr/bin/env bash
#
# lib/duration.sh — parse_duration HOURS
#
# Echoes integer seconds = round(HOURS * 3600).
# Rounding uses awk: printf "%d", h*3600 + 0.5  (round-half-up).
#
# Validation:
#   - HOURS must be a positive number (> 0).
#   - Empty, non-numeric, zero, or negative values print an error to stderr
#     and return non-zero.
#
# Requires: bash 3.2+, awk

parse_duration() {
  local hours="$1"

  # Validate: non-empty
  if [[ -z "$hours" ]]; then
    echo "parse_duration: HOURS must not be empty" >&2
    return 1
  fi

  # Validate: numeric and positive using awk
  # awk prints 1 if valid positive number, 0 otherwise.
  local valid
  valid="$(awk -v h="$hours" 'BEGIN {
    # Check numeric: attempt arithmetic; if it produces 0 for a non-numeric
    # string, the regex will catch it.  Use a regex to be safe.
    if (h ~ /^-?[0-9]+(\.[0-9]+)?$/ || h ~ /^-?\.[0-9]+$/) {
      print (h + 0 > 0) ? "1" : "0"
    } else {
      print "0"
    }
  }')"

  if [[ "$valid" != "1" ]]; then
    echo "parse_duration: HOURS must be a positive number, got: '${hours}'" >&2
    return 1
  fi

  # Compute and echo integer seconds (round-half-up)
  awk -v h="$hours" 'BEGIN { printf "%d\n", h * 3600 + 0.5 }'
}
