#!/usr/bin/env bash
set -euo pipefail

limit="${1:-60}"
status=0

awk -v limit="$limit" '
  /^[[:space:]]*(static[[:space:]]+)?[A-Za-z_][A-Za-z0-9_[:space:]\*]+[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^;]*\)[[:space:]]*\{/ {
    in_function = 1
    depth = 0
    start = FNR
    name = $0
  }
  in_function {
    line_count += 1
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "{") depth += 1
      if (c == "}") depth -= 1
    }
    if (depth == 0) {
      if (line_count > limit && name !~ /long-function-allowed/) {
        printf "%s:%d function exceeds %d lines (%d): %s\n", FILENAME, start, limit, line_count, name
        status = 1
      }
      in_function = 0
      line_count = 0
    }
  }
  END { exit status }
' Sources/Labpty/*.c
