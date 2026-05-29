#ifndef LABPTY_CONTRACTS_H
#define LABPTY_CONTRACTS_H

/* CBMC code-contract annotations, gated like the <ptrcheck.h> bounds-safety
 * macros next door: zero-cost in every normal build, real CPROVER contract
 * clauses only when the DFCC proof pipeline compiles with -DLABPTY_CONTRACTS
 * (see scripts/check-cbmc-contracts and docs/process/formal-specs.md).
 *
 * Function contracts (REQUIRES/ENSURES/ASSIGNS) and loop contracts
 * (LOOP_INVARIANT/LOOP_ASSIGNS/DECREASES) let goto-instrument prove the
 * decoders UNBOUNDED — for every input length, not just up to a small
 * --unwind — and let a caller be verified modularly by replacing an inner
 * helper with its contract. With the macros disabled they expand to
 * nothing, so production code and the bounded proofs in frame_proof.c are
 * byte-for-byte unaffected. */

#ifdef LABPTY_CONTRACTS
#  define LABPTY_REQUIRES(...)       __CPROVER_requires(__VA_ARGS__)
#  define LABPTY_ENSURES(...)        __CPROVER_ensures(__VA_ARGS__)
#  define LABPTY_ASSIGNS(...)        __CPROVER_assigns(__VA_ARGS__)
#  define LABPTY_LOOP_INVARIANT(...) __CPROVER_loop_invariant(__VA_ARGS__)
#  define LABPTY_LOOP_ASSIGNS(...)   __CPROVER_assigns(__VA_ARGS__)
#  define LABPTY_DECREASES(...)      __CPROVER_decreases(__VA_ARGS__)
#else
#  define LABPTY_REQUIRES(...)
#  define LABPTY_ENSURES(...)
#  define LABPTY_ASSIGNS(...)
#  define LABPTY_LOOP_INVARIANT(...)
#  define LABPTY_LOOP_ASSIGNS(...)
#  define LABPTY_DECREASES(...)
#endif

#endif
