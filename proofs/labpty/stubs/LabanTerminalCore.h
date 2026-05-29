#ifndef LABAN_TERMINAL_CORE_H
#define LABAN_TERMINAL_CORE_H
/*
 * CBMC-only stub.
 *
 * The labpty wire-format decoders (labpty_frame.c, labpty_protocol.c)
 * pull in include/labpty_internal.h, which includes the real
 * <LabanTerminalCore.h> for the rest of the daemon. The decoders
 * themselves use nothing from it, so the proofs — and the compile-only
 * drift smoke in scripts/check-cbmc — resolve this name to an empty
 * header instead of dragging the 30 KB terminal-core API (and its
 * transitive system headers) through CBMC's frontend.
 *
 * If a decoder ever starts depending on a real LabanTerminalCore type,
 * the smoke compile fails here and this stub must grow the needed
 * declaration (or the proof must add -I Sources/LabanTerminalCore/include
 * and drop this stub).
 */
#endif
