#!/usr/bin/env bash
set -euo pipefail

if command -v xcrun >/dev/null 2>&1; then
  compiler=(xcrun --sdk macosx clang)
else
  compiler=(clang)
fi

if ! printf 'int main(void) { return 0; }\n' |
  "${compiler[@]}" -fsyntax-only -fbounds-safety -x c - >/dev/null 2>&1
then
  echo "bounds-safety headers: skipped; compiler does not support -fbounds-safety"
  exit 0
fi

status=0
for marker in __sized_by __counted_by __single; do
  if ! rg -q "$marker" Sources/Labpty; then
    echo "bounds-safety headers: missing annotation marker $marker"
    status=1
  fi
done
if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

smoke="$(mktemp "${TMPDIR:-/tmp}/labpty-bounds-headers.XXXXXX.c")"
trap 'rm -f "$smoke"' EXIT
cat >"$smoke" <<'C'
#include "labpty_frame.h"
#include "labpty_protocol.h"
#include "labpty_byte_ring.h"
#include "labpty_registry.h"

int main(void) {
    return 0;
}
C

"${compiler[@]}" \
  -fsyntax-only \
  -fbounds-safety \
  -Wall \
  -Wextra \
  -Wpedantic \
  -I Sources/Labpty/include \
  -I Sources/Labpty \
  -I Sources/LabanTerminalCore/include \
  "$smoke"

echo "bounds-safety headers: ok"
