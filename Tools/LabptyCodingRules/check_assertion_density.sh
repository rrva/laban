#!/usr/bin/env bash
set -euo pipefail

awk '
  /^[[:space:]]*(static[[:space:]]+)?[A-Za-z_][A-Za-z0-9_[:space:]\*]+[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^;]*\)[[:space:]]*\{/ {
    functions += 1
  }
  /assert[[:space:]]*\(/ {
    assertions += 1
  }
  END {
    if (functions == 0) {
      print "no functions found"
      exit 1
    }
    ratio = assertions / functions
    printf "assertions=%d functions=%d ratio=%.2f\n", assertions, functions, ratio
    exit ratio >= 2.0 ? 0 : 1
  }
' Sources/Labpty/*.c
