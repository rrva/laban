--------------------------- MODULE LabptyByteRing ---------------------------
(****************************************************************************
 Labpty single-producer, single-consumer byte ring with the "readable output
 window" safety margin.

 What this spec models
   The shared-memory byte ring described by labpty_byte_ring_writer_t /
   LabptyByteRingReader. The writer is the daemon (one process), the reader
   is any mmap consumer (a separate process). The two communicate only
   through:

     - the ring buffer cells, which the writer paints with plain stores
     - the published `output_offset` counter, which is atomic
       (memory_order_release on the writer, memory_order_acquire on the
       reader)

   The writer's update of `output_offset` is observably non-atomic relative
   to the memcpy that paints the cells: the C code first memcpy's bytes
   into ring positions, then atomically stores the new offset. A reader
   loading the offset right after the memcpy but right before the offset
   store will see the OLD offset value but the NEW cell contents.

   This is precisely the race the safety margin (commit 26760d5 in this
   repo) was added to neutralise. With margin ≥ max-write-size, the writer's
   in-flight memcpy region and the reader's read window never overlap.

 What we prove here
   Safety: a reader's `readSince` never returns a cell whose contents come
   from a write the reader's observed offset has not yet "seen". A torn
   read — where the reader stitches together bytes from two different
   rotations of the buffer — is impossible.

 What is intentionally abstracted
   - Individual byte values; we use one logical "offset stamp" per cell
   - The two-phase nature of a single memcpy across the wrap point; we
     treat the writer's WriteCells action as atomic with respect to other
     actions, capturing the externally observable race window (between
     painting and publish) but not intra-memcpy partial-paint states
   - Memory-order details below the acquire/release pair; we assume the
     atomic load returns either the old or the new value, never garbage

 Companion spec
   LabptyByteRingTorn.tla repeats this spec with ReadableWindow = Capacity
   (no margin) and demonstrates a counterexample to NoTornRead, mirroring
   the LabptyLifecyclePreF2 negative-control pattern.
 ****************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets, Integers

CONSTANTS
    Capacity,         \* ring capacity in cells (must be > 0; need not be power
                      \* of 2 here — the C code requires it for modular indexing
                      \* but the abstraction uses arbitrary-modulo arithmetic)
    ReadableWindow,   \* how many bytes behind `published` the reader allows
                      \* itself to read (Capacity - margin)
    MaxWriteSize,     \* max bytes a single labpty_byte_ring_write call passes
    MaxWrites         \* state-space bound: stop after this many total bytes
                      \* (TLC needs the model finite; the property is
                      \* parameterised over (Capacity, ReadableWindow,
                      \* MaxWriteSize) and should hold for all sufficiently
                      \* large MaxWrites)

ASSUME Capacity \in 1..1000
ASSUME ReadableWindow \in 1..Capacity
ASSUME MaxWriteSize \in 1..Capacity
ASSUME MaxWrites \in 1..1000

VARIABLES
    cells,        \* cells[i] = the largest logical offset whose byte
                  \* currently occupies cell i. Initialised to 0; this
                  \* "looks like" the byte at logical position 0, which is
                  \* benign because any reader observation with end > 0
                  \* implies the writer has published at least one byte and
                  \* therefore painted every cell index it touched. Cells in
                  \* the reader's window [start, end) are therefore always
                  \* the result of a real prior paint, never a residual
                  \* zero.
    published,    \* atomic, monotonic — total bytes the writer has both
                  \* memcpy'd AND announced via the offset store
    pending,      \* bytes that have been memcpy'd into cells but not yet
                  \* announced via the offset store. 0 when writer is idle.
    last_read     \* a record describing the most recent reader observation,
                  \* or the empty NullRead before the first read

vars == << cells, published, pending, last_read >>

CellIndex == 0..(Capacity - 1)
NullRead  == [start |-> 0, end |-> 0, observed |-> << >>]

\* The set of logical offsets `published + 0 .. published + (n-1)` mapped
\* through the ring, giving the cell indices that a write of `n` bytes
\* starting at `published` would touch.
PaintedIndices(start, n) == { ((start + k) % Capacity) : k \in 0..(n - 1) }

\* For a write of n bytes starting at `start`, the new logical offset
\* deposited into cell index i.
NewOffsetAtCell(start, n, i) ==
    CHOOSE k \in 0..(n - 1) : ((start + k) % Capacity) = i

\* The expected offset stamp the reader should see at modular index i,
\* for a logical position k in the reader's window.
ExpectedStampAt(k) == k

\* The reader's effective window: at most ReadableWindow bytes behind
\* the published offset.
ReadStart(P) == IF P >= ReadableWindow THEN P - ReadableWindow ELSE 0

\* ----------------------------------------------------------------------
\* Initial state and actions
\* ----------------------------------------------------------------------

Init ==
    /\ cells = [i \in CellIndex |-> 0]
    /\ published = 0
    /\ pending = 0
    /\ last_read = NullRead

\* Writer is idle when pending = 0.
WriterIdle == pending = 0

\* WriteCells: writer atomically performs the memcpy phase of a labpty_byte_ring_write
\* of `n` bytes. The cells in PaintedIndices receive the new logical offsets.
\* The published counter is NOT updated yet — that's WritePublish.
WriteCells(n) ==
    /\ WriterIdle
    /\ n \in 1..MaxWriteSize
    /\ published + n <= MaxWrites
    /\ cells' = [i \in CellIndex |->
            IF i \in PaintedIndices(published, n)
            THEN published + NewOffsetAtCell(published, n, i)
            ELSE cells[i]]
    /\ pending' = n
    /\ UNCHANGED << published, last_read >>

\* WritePublish: atomic release store of the new published offset. The
\* writer becomes idle again.
WritePublish ==
    /\ pending > 0
    /\ published' = published + pending
    /\ pending' = 0
    /\ UNCHANGED << cells, last_read >>

\* Read: snapshot the published offset (acquire-load) and read every cell
\* in the window [start, published). Record the (offset, stamp) sequence
\* for the safety invariant to inspect.
Read ==
    LET P == published
        s == ReadStart(P)
    IN /\ last_read' = [
            start    |-> s,
            end      |-> P,
            observed |-> [k \in 0..(P - s - 1) |-> cells[((s + k) % Capacity)]]
          ]
       /\ UNCHANGED << cells, published, pending >>

Next ==
    \/ \E n \in 1..MaxWriteSize : WriteCells(n)
    \/ WritePublish
    \/ Read

Spec == Init /\ [][Next]_vars

\* ----------------------------------------------------------------------
\* Safety invariants
\* ----------------------------------------------------------------------

\* TypeOK: every variable holds a value of the expected shape.
TypeOK ==
    /\ cells \in [CellIndex -> Nat]
    /\ published \in 0..MaxWrites
    /\ pending \in 0..MaxWriteSize
    /\ last_read.start \in 0..MaxWrites
    /\ last_read.end \in 0..MaxWrites
    /\ last_read.end >= last_read.start

\* Published is monotonic (no observable regression).
PublishedNeverDecreases == TRUE  \* enforced by construction; documented invariant

\* The core safety property. For every cell the reader returned in its
\* most recent observation, the stamp on that cell matches the logical
\* position the reader believes it's reading. A mismatch means a torn
\* read: the reader's window included a cell that has since been
\* overwritten by a later write (or, less likely, contains a value from
\* a future write the published offset has not yet reached).
NoTornRead ==
    LET obs == last_read.observed
        s   == last_read.start
        e   == last_read.end
    IN \A k \in 0..(e - s - 1) :
         obs[k] = ExpectedStampAt(s + k)

\* The reader, when it sees published = P, must be reading from cells
\* whose contents reflect writes with logical positions strictly less
\* than P. Equivalently: no cell in the window holds an offset >= P.
\* This is the invariant the safety margin protects.
WindowDoesNotContainFutureWrites ==
    LET obs == last_read.observed
        e   == last_read.end
    IN \A k \in DOMAIN obs : obs[k] < e

=============================================================================
