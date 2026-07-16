# sim6564 — Reference Simulator, v0.1 Implementation Record

Companion to [6564-net-architecture-v2.md](6564-net-architecture-v2.md). The
spec says what the machine *is*; this records what v0.1 of the simulator
*decided* where the spec left latitude, what it deliberately simplifies, and
what building it taught us. Zig 0.14.1.

## Layout of the code

| File | Role |
|---|---|
| `src/isa.zig` | Declarative ISA table — the single source of truth. Decoder generated at comptime; duplicate opcodes are compile errors. |
| `src/ring.zig` | Pure layouts: ring descriptors, SQ/RX/CQ entry formats, PTT entries, window pointers. No machine state. |
| `src/mesh.zig` | Fault-injection policy: latency, jitter, loss, duplication — all from one seeded PRNG. |
| `src/machine.zig` | Contexts, cores, memory decode, the interpreter, the hardware scheduler, the discrete-event loop. |
| `src/asm.zig` | Two-pass assembler driven by the same ISA table. |
| `src/integration_tests.zig` | Assembled programs run end-to-end, §6 semantics exercised. |
| `src/programs/*.asm` | The actual 6564 programs: ping/pong, supervisor/worker, pipe_source/stage/sink. |
| `src/demo_*.zig` | Demo harnesses (wiring, staging, reporting); also driven by the test suite. |
| `src/main.zig` | CLI dispatcher over the demos. |

`zig build test` runs everything. Demos:
`sim6564 [pingpong] [seed] [loss_ppm4k] [rounds] [trace]`,
`sim6564 supervise [trace]`, and
`sim6564 pipeline [seed] [loss_ppm4k] [items] [stages] [trace]`.

## Concrete decisions (spec-compatible, but v0.1 chose)

**Opcode numbering.** Inherited 6502/65C02 instructions keep their classic
opcode bytes (`LDA #imm` = `A9`, the 65C02 zp-indirect column becomes
near-indirect, `HLT` sits in STP's `DB`). New I/O/concurrency ops occupy the
`0x?7` column NMOS never defined; imm64 variants sit in `0x?3`.

**Near page: 4 KB, of which the bottom 2 KB is the descriptor table** — 64
slots × 32 bytes. Slots 0/1/2 are architecturally the context's SQ/CQ/default
RX ring. The top 2 KB is software scratch (`$800`–`$FFF`).

**Ring descriptor format** (see `ring.zig` doc comments for bit layout):
base, capacity (power of two), entry size, watermark, companion-CQ slot,
free-running head/tail (hardware masks; software never wraps), capability
token. `count = tail -% head` — full at `count == capacity`.

**Doorbell discipline.** Software *stages* an entry at the ring's tail slot in
RAM, then executes `SEND`/`RECV`, which advances the tail. `CQPOP` pops the
head. The spec's "doorbell-free snooping" is modeled as these explicit
instructions; the ring state transitions are identical.

**Completion record** (16 bytes): `word0 = tag | status<<8 | count<<32`,
`word1 = cookie`. `CQPOP` loads word0→A, cookie→X, Z set when empty. Status
codes: ok, truncated, reject_capability, reject_no_buffer, timeout.

**Address decode per context:** `$0000`–`$0FFF` near page (private),
`$1000`+ core RAM, top byte `$FF` = network window (16-bit PTT index in bits
55:40, 40-bit offset).

**Sim addressing convention.** A PTT entry's IPv6 prefix low word carries the
mesh coordinates the simulator routes by: dst core [0..16), dst context
[16..24), dst RX descriptor slot [24..32). Prefix high word is cosmetic
(`fd65:6400::/32`).

**Scheduling.** Cooperative: a context runs until it parks (`LSTN`), yields
(`YLD`), halts, or faults. The bank switch costs zero cycles per §2.2. Cores
advance private clocks; the machine steps whichever busy core is furthest
behind, and events fire when virtual time passes them. Ties break by core
index / event sequence number → bit-identical replay from a seed.

**Supervision (Phase 3, spec §5.4).** Exit links are per-context
`(supervisor ctx, CQ slot)` pairs set by the harness (`linkSupervisor`); on
halt/fault the machine posts the exit completion. `SPWN` resets the target's
registers, bumps its incarnation counter, and queues its continuation; the
near page and exit link survive. Run-queue entries carry the incarnation
number, so a dead life's continuations are skipped at dispatch. `SPWN` of
self or an out-of-range context faults the spawner (`bad_descriptor`).
Same-core only — cross-core supervision is a software protocol.

**Watchdog (spec §5.4).** `setWatchdog(core, ctx, cycles)` arms a per-context
burst budget (0 = off; survives SPWN, like the exit link). The check runs
between instructions against the dispatch-time clock: exceed the budget and
the context faults with code `watchdog`, `stats.watchdog_trips` increments,
and the exit link fires. Instructions stay atomic — the trip lands after the
instruction that crossed the line.

## Deliberate v0.1 simplifications

1. **The RBC drains SQs instantly.** `SEND` accepts and transmits in the same
   cycle; the SQ never stays full, so "SEND parks on full SQ" (§5.2) is
   defined but unexercised. A drain-rate model is a Phase 3 refinement.
2. **Watermarks are stored but not acted on** — `LSTN` wakes on non-empty
   only. Threshold events beyond that are future work.
3. **`RECV` on a full ring faults** (`bad_descriptor`). Posting to a full
   ring is a software bug; the fault is honest. (Parking instead is a
   defensible alternative — revisit with real workloads.)
4. **Remote loads fault** (`remote_load`). Remote reads are a software
   protocol (SEND a request, RECV the answer), not a synchronous bus op.
   Stores through the window become single-word datagrams (TXR semantics);
   the PTT `write` right is reserved for future registered-region RDMA
   writes, and the window offset is carried but not yet interpreted.
5. **Contexts on one core share RAM above the near page.** Actor purity
   (spec open question 3) says they shouldn't share mutable state; v0.1
   trusts software. The near page *is* enforced private.
6. **Single privilege level.** `CAPLD` is executable by anyone; the
   privileged/unprivileged split (open question 4) is not yet modeled.
7. **CQ overflow drops the completion and counts it** (`stats.cq_overflows`).
   Size CQs generously. io_uring-style overflow handling is future work.
8. **The ownership bit is cleared by RAM address** captured at accept time.
   If software reuses an SQ slot before its completion posts, the clear can
   land on the reused entry — consistent with §6.2's "undefined effect" for
   software that touches in-flight state.

## What building it taught us (feed back into the spec)

**The fabric is a clock.** The ISA has no timer, and a real end-to-end
protocol *needs* one: the "send acked OK but the reply was lost" case leaves
the sender with nothing outstanding and nothing ever arriving — an
unrecoverable park. The idiom that fixes it: **send to an unroutable PTT
prefix**. The datagram vanishes; the mandatory timeout completion arrives
exactly `send_timeout` cycles later. Software gets its retransmission timer
from the fabric's honesty alone, no new silicon. The demo's ping actor runs a
persistent timer chain this way. *Blessed:* this is now normative — spec §6.3,
"Timers: the Fabric as Clock". Per-send timeout values and a fixed black-hole
slot number remain open.

**Landed-but-unwanted still consumes the buffer.** A sequence-checking
receiver that ignores a stale duplicate must still re-post its landing
buffer: the reject/accept decision is the application's, but the *consumption*
already happened in hardware. Missing this deadlocked the first demo protocol.
The pattern: repost on every `ok` delivery completion, wanted or not.

**Transport acks are nearly useless to applications.** The demo's first
protocol acted on SEND acks ("delivered, so stop retransmitting") and
deadlocked; the working protocol ignores them entirely and trusts only
end-to-end evidence (the echo) plus timers. This is the end-to-end argument
reproduced from first principles in ~60 instructions. The CQ ack still
matters for one thing: buffer ownership release (§6.2).

**Supervision cannot reach the compute-hung — without a watchdog.** Exit
links catch halts and faults, but a worker spinning in a pure compute loop
starves the whole core — including its supervisor, which can then neither
observe nor restart it (a regression test pins this failure mode down). The
fix became spec §5.4's watchdog burst budget: one comparator, and the hang
turns into an ordinary fault the existing exit link reports. The demo's
worker 4 exercises the full arc — hang, trip, restart, budget exhaustion.
Open question 7: resolved.

**One program, many actors.** All three demo workers execute the same code at
one RAM address with per-actor config blocks passed via the spawn argument —
shared read-only code pages in practice, which is the "stated position"
spec open question 3 asks for.

**Ack-on-ownership is the whole of pipeline flow control.** The pipeline
demo's stages ack upstream the moment they take ownership of an item — not
when it reaches the sink — which is what lets hops overlap. And the *absence*
of an ack (HOLD full → drop silently) is complete backpressure: upstream's
retransmission timer becomes the retry-with-delay loop for free. No credit
protocol, no window negotiation; the whole discipline is "ack when you have
room, stay silent when you don't."

**Nothing with an upstream may die.** First pipeline shutdown design: a stage
halts once its DONE forward is acked. Wrong — its own ack upstream can be
lost, leaving upstream retransmitting at a corpse forever, hop after hop.
The fix generalizes the immortal-sink insight: a finished stage goes **lame
duck** — parked, serving re-acks, timer chain allowed to die — so the
machine quiesces instead of being kept awake, and every straggler upstream
still converges. Termination over an unreliable fabric is a *phase*, not an
instruction.

**Software memory maps are the sharp edge.** The pipeline's first wiring put
CQ ring storage ($2000, 32×16 B) overlapping the RX descriptor staging at
$2100; once the CQ wrapped, completion records silently overwrote the staged
RX entries and every node wedged with honest-looking `no_buffer` rejects.
Hardware validates tokens and rights but not ring-storage overlap — it
can't; RAM layout is software's contract. Worth remembering when the OS
layer arrives.

**Idempotence beats acknowledgment.** Scatter-gather needs no ack protocol
at all: the result is the ack, workers recompute on duplicate requests, and
the coordinator dedups by worker id. Where the pipeline had to build
ownership transfer, request-response just needs a retry timer and stateless
servers. Choosing *what* to make reliable is the protocol design.

**Duplicate reject acks race genuine ok acks.** When a duplicated datagram's
second copy finds no buffer, its reject ack can overtake the first copy's ok
ack; first-ack-wins means a sender can be told "no buffer" about a message
that was delivered. This is truthful (each report describes one copy's fate)
but subtle — worth a normative sentence in §6.1.

## Stats and tracing

`Machine.stats`: instructions, context switches, sends, delivered, lost,
duplicated, timeouts, rejects, unroutable, CQ overflows. `Config.trace`
prints scheduler/RBC/fabric events with cycle stamps to stderr — the demo
takes `trace` as its 4th CLI arg.

## Phase status (§9 of the spec)

- **Phase 1 — deterministic core: done.** Comptime-decoded ISA, banked
  contexts, near-page descriptors, continuation queue, single-core queue
  pairs, cycle-stepped clock.
- **Phase 2 — virtual mesh: done.** Multi-core, PTT routing, seeded
  loss/latency/reorder/duplication on off-chip paths (acks included —
  two-generals is live), deterministic replay verified by test.
- **Phase 3 — actor workloads: complete.** Ping-pong with end-to-end
  reliability (`sim6564 pingpong`); a one-for-one supervision tree with
  exit links, SPWN restarts, per-child budgets, and watchdog-caught hangs
  (`sim6564 supervise`); pipeline dataflow over N cores with per-hop
  stop-and-wait, ack-on-ownership overlap, backpressure by silence, and
  lame-duck shutdown — every item checksum-verified through 73% loss
  (`sim6564 pipeline`); scatter-gather fan-out/fan-in with idempotent
  workers, straggler re-scatter, and a capacity-8 RX ring absorbing the
  result burst (`sim6564 scatter`). The spec's three representative
  workloads all run, entirely from CQ feedback and the primitives of §5–§7
  — no ISA additions were needed beyond §5.4's supervision pair.
