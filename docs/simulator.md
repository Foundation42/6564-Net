# sim6564 — Reference Simulator, v0.1 Implementation Record

Companion to [6564-net-architecture-v2.5.md](6564-net-architecture-v2.5.md). The
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
`0x?7` column NMOS never defined; imm64 variants sit in `0x?3`; counted
shifts (`LSR #n` etc., v2.5) sit in `0x?B` at 2 cycles flat.

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
halt/fault the machine posts the exit completion, cookie = context id |
incarnation << 32, so supervisors can discard obituaries from lives they
already replaced. `SPWN` resets the target's
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

## The MAC & chains mechanisms (campaign concluded; spec v2.2)

Adoption status: **SQE format, LINK + chain_cancelled, AUTO_REARM are
normative** (spec §4.2–§4.3). AUTO_REPOST is a permitted optional
implementation feature. MAC remains pre-normative, deferred with its data.

**`MAC n`** ($0F–$FF, the whole $?F column): one-byte vectored call —
exactly `JSR [MACTAB + n*8]`, MACTAB at near $F80–$FFF, per-context, so
vectors travel with the actor and survive SPWN. Null vector →
`bad_macro` fault. `stats.macro_calls`. Adoption verdict deferred — see
docs/measurements.md: the current corpus can't feed it (3.6% max code-byte
saving), so it awaits the chain features and richer workloads.

**32-byte SQE** (sketch §2, now the only submission format): op | flags
(bit 7 OWNED) | link | hint, target, buf/value, len | cookie_lo. SEND
dispatches by op (`send`, `txr`; others fault). Completion cookies carry
the hardware stamp (cookie_lo | staging-slot<<32 | incarnation<<48);
completion word0 bits 16..24 carry the source-ring slot. Verified no-op
dynamically.

**AUTO_REPOST** (ring-descriptor flag): on CQPOP of a landed delivery
from a flagged RX ring, hardware re-enqueues a landing buffer — with the
**deferred grant**: each pop re-arms the *previous* pop's buffer, so a
popped payload is valid until the next CQPOP from that ring,
unconditionally. (The first design granted the just-consumed buffer
immediately; the Big Brother stress test proved that collapses the
validity window to zero exactly when a flood drains the ring dry —
checksums corrupted until the grant was deferred.) Capacity-1 rings
fault at first trigger. Measured flat-to-negative on the protocol corpus
but load-bearing at the fan-in sink; its other value is making the
missed-repost bug class unrepresentable. Status: optional implementation
feature, not architectural.

**AUTO_REARM** (SQE flag bit 1): an entry completing with `timeout` is
re-read from its staging bytes and resubmitted by the RBC — a timeout is
a tick. The re-read is the disarm: clear the flag (one word store; the
demos fold it into their shutdown/lame-duck transition) and the chain
dies at its next firing, at most one stray tick later. Fires on status
alone; on a routable target this is retransmit-until-acked, permitted
but subject to §6.1's copies-not-messages caveat. All four demo timer
chains use it: stage once, one arming doorbell, no rearm handler.

**LINK + `chain_cancelled`** (SQE flag bit 0 + status 6): on an ok
completion, the RBC submits the staged entry at the near-page offset in
`link`; on any other outcome it posts `chain_cancelled` for every
remaining entry (walk capped at 16) — stage N, collect N records,
always. Rearm takes precedence over cancellation on the same entry.
Scatter's fan-out is a live chain: one doorbell sends all W tasks
sequentially on transport-ok, a lost task breaks the chain loudly, and
the straggler timer re-scatters the cancelled. −24% instructions on
that demo. Fixed en route: local PTT rights-rejects now route through
the normal completion path (they previously leaked OWNED and would have
skipped cancellation).

## Capstone stress tests

`sim6564 bigbrother` (10,000 senders → one target) and `sim6564 forkjoin`
(1 → 1,000 → 1,000 relays → 1) — results in measurements.md. Three
machine-level consequences, all regression-tested: the **admission rule**
(a delivery is accepted only if a landing buffer AND a completion slot
exist — CQ-full is backpressure, answering open question 6 for the
simulator); **no_buffer rejects report to the sender only** (flow
control, not a security event — receiver-side reject records would crowd
landed records out of a flooded CQ; capability rejects still post both
ends); and AUTO_REPOST's **deferred grant** (above). Architectural data:
fan-out degree is bounded by PTT size (256/core, shared by the core's
contexts) and LINK chains by near-page scratch (~59 entries), so big
fan-out is hierarchical by construction.

## The peripheral row (spec §7, v2.3)

Devices live in `src/dev.zig` as pure policy (payload in → status +
optional reply out); `machine.zig` owns routing, tokens, and the event
queue. A `DevEndpoint` is `{device, token, 16-entry PTT}` in a hashmap
keyed by mesh coordinate ($FF00–$FFFE; $FFFF stays the black hole).
`sendDatagram` treats a device coordinate as routable; `deliver()`
branches to `deliverToDevice`, which token-gates, applies the request at
fabric time, acks the sender through the ordinary path, and fires any
reply through the device's own PTT as fresh fire-and-forget datagrams
(never in `pending` — no ack sought, and the reply crosses the same
lossy links as everything else). Zero new opcodes; zero cycle-model
changes; null cost verified — `sim6564 measure` reproduces the frozen
table byte-identically with no devices attached.

v1 devices: **console** (bytes → transcript; `Console.echo` for live
write-through), **entropy** (own seeded PRNG, deliberately separate from
the mesh PRNG so attaching it can't perturb fault injection; count
clamped to 64), **rtc** (replies with the request's arrival cycle),
**block** (init-time sector count/size, size 8..512; write applies at
delivery so the fabric ack is the write ack).

Demos: `sim6564 hello` (programs/hello.asm — one send, one teletype) and
`sim6564 periph` (programs/periph.asm — walks all four devices,
timestamps its errand off the RTC, hex-prints an entropy draw glyph by
glyph through a one-byte char SQE, verifies a sector round-trip, prints
its own cycle bill).

**Driver lesson (recorded in spec §7.3):** a device reply can race its
own request-ack home — the ack and the reply leave the device at the
same fabric instant on independently-jittered paths. periph.asm's
ack-wait therefore stashes any delivery record it pops ($8B0/$8B8) for
the reply-collector to pick up. Sequential request/reply protocols need
one stash slot; pipelined ones need a real dispatch loop.

## The IO plane (spec §6.5, v2.4)

`src/cluster.zig` joins N complete Machines (dies) under a
conservative-horizon window loop; each die's single-threaded event loop
is untouched (`run()` is now literally `runUntil(∞)`, verified
byte-identical against the frozen table). The window equals the plane's
base latency, so traffic emitted in window k is due no earlier than
window k+1 and barrier injection never hands a die an event in its past
(a core may overshoot the horizon by one instruction — the same
tolerance the event loop always had). Machine-side hooks: `attachPlane`
(die id + egress callback), egress on PTT route byte != 0 (timeout still
arms locally), `injectDeliver`/`injectAck` for barrier ingress, and
datagrams carry `src_die` so a foreign delivery's ack rides the plane
home instead of touching the local pending map — send-ids are per-die
counters, and the first draft's failure to stamp origin produced 1,510
acks for 40 datagrams before the plane's counters caught it.

Determinism at any thread count: within a window dies share nothing
(each owns its outbox and plane PRNG and rolls its own egress faults);
the barrier merge sorts by (due, src_die, seq). `parallel = true` runs
one persistent worker thread per die — persistent because
thread-per-window burned 3.7x the sequential wall clock in spawn/join
before the pool. Release builds use `std.heap.smp_allocator`
(main.zig): the shared-mutex GPA was the real end-to-end bottleneck
(7.7 s → 1.0 s sequential on the busy benchmark). Cluster requires a
thread-safe allocator when parallel (GPA default config and
testing.allocator qualify).

Demo: `sim6564 dies [dies] [nodes] [laps] [busy_laps] [seq]` — the ring
spans dies with ring_node.asm unmodified; remoteness is one route byte.
`busy_laps > 0` adds a die-local ring per die so all host threads have
work: the lone global token is Amdahl's law incarnate (one busy die at
a time), and the harness says so rather than pretending. Numbers in
measurements.md; bit-identity threaded-vs-sequential is test-guarded.

Thread placement (`src/topology.zig`, vendored from substr): pin die
threads by L3 domain with `spread | vcache | freq` — built for the
asymmetric 9950X3D host (one V-cache CCD, one frequency CCD). Measured
findings (ledger): pinning at all is the big win (~20-25%, takes the
16-thread speedup from 3.7x to 6.1x — the scheduler stops migrating
workers across CCDs); at 8 dies one CCD beats two (barriers stay in one
L3); vcache vs freq is a wash until per-die footprints outgrow the
small CCD's 32 MB. Placement never changes results — md5-identical
output across all five policies.

**The socket bridge** (`src/bridge.zig`, `sim6564 net`): the plane
between HOST PROCESSES. Die ids federate — a cluster owns
[node_base, node_base+dies); routes to foreign ids leave through the
`Exchange` hook at every window barrier, which the bridge implements as
a framed TCP swap (HELLO validates version/window/seed/range-disjoint;
per window both sides send their frame then read the peer's — a true
barrier). Frames carry VIRTUAL due-times, so determinism survives the
socket: the federation replays bit-identically from its seeds no matter
what the real network does (test-guarded, including threaded-vs-
sequential). Distributed termination without a consensus round: each
frame carries a quiescent flag = "terminal and moved nothing this
window"; both sides evaluate (mine AND peer's) from the same window's
frames and agree on the stopping window. Ownership rule: outgoing items
stay cluster-owned (the bridge serializes, never retains); inbound
payloads are allocated from the receiving cluster's allocator so
`deliver()` frees them normally. Known v1 cost: one socket RTT per
window (lock-step); PDES null-message/lookahead batching is the obvious
refinement if federations ever get chatty. If one process dies, the
peer blocks on read — Ctrl-C, not corruption.

`sim6564 churn` is the experiment that makes the X3D asymmetry speak:
each die read-modify-writes a multi-MB stripe in maximal-period LFSR
order (programs/mem_churn.asm). The order matters — a linear +64 stride
measured *nothing* at 64 MB live because the host prefetcher hid all
capacity effects; defeat the prefetcher first, then measure the cache.
Result: parity at 16 MB live, **1.40x for the V-cache CCD at 64 MB**
(fits 96 MB, thrashes 32 MB), narrowing to 1.15x at 128 MB when both
CCDs overflow. Cluster runs now end with a per-die retirement table
(`cluster.writeStatsTable`): cycles, instructions, sends, delivered,
rejects, timeouts, context switches per die plus totals and plane
traffic.

## The net device and the web capstone (spec §7.4/§7.5, v2.5)

`dev.Net` is the raw byte pipe: open (real DNS + TCP connect), send,
recv (bounded poll — the ONE place the event loop may hold for real
milliseconds; it is the wall-clock boundary anyway), close. Stream
semantics need no in-band framing: an empty recv reply means "ask
again", a rejected recv request means EOF — the ack vocabulary
suffices. Determinism scope (spec §7.4): the outside world does not
replay; machines without a Net attached are unaffected.

`programs/http_get.asm` + `sim6564 web [host] [port] [path]`: HTTP/1.1
entirely in 6564 code, chunks forwarded straight from the landing
buffer to the console (AUTO_REPOST's deferred grant covers the console
ack wait). Tests run it hermetically against a local TCP server thread.
Driver lesson #2, earned the slow way: **a shared staged SQE is mutable
state — set every field you depend on, every submission.** http_get's
pump set the SQE buffer each lap but not the target; after the first
console print, the next recv request went to the teletype (which
printed it) and the data reply never came. The retirement stats made
the diagnosis arithmetic: 104 console bytes = 80 response + 24 = one
recv request, verbatim.

## WDEX: bounded declarations (post-v2.5 handoff item 1)

`WDEX ##n` ($B7, imm64, 3 cycles) sets the current burst's remaining
watchdog budget to `n`, checked against a per-context **declaration
ceiling** (`Machine.setWdexCeiling` — privileged like the base budget,
survives SPWN; the actor must not edit its own leash). Implementation:
the declaration lives on the Core (`wdex_base`/`wdex_budget`) because
only the context holding the pipeline can have one, and `dispatch()`
clears it — a declaration structurally cannot outlive its burst.
Over-ceiling declarations fault (`wdex_ceiling`, bad_descriptor-class);
a second WDEX replaces; `##0` cancels; with no watchdog armed WDEX is
an architectural no-op (nothing to extend — joe's `bounded` blocks run
identically supervised or not). This is the lowering target for joe's
`bounded N { … }`. Null-cost verified against the frozen v2.5 table.

## The extended page and Tier 0 scalar FP (post-v2.5 handoff items 2)

Prefix **$42** — the 65816's WDM, the one byte that family reserved
for expansion — opens a second 256-entry opcode page (`isa.xtable` /
`isa.xdecode`, same comptime duplicate detection). Non-stacking by
construction: $42 is null on the extended page, so `$42 $42` faults
`bad_opcode`. `Encoding` gained a `page` field; `size()` includes the
prefix, so the assembler and `exec` agree on layout for free; the
assembler's only change was writing the prefix byte in `emit`.

Tier 0 FP is accumulator-shaped: FP64 bits live in A, `loadOperand`
supplies M, and FLDS/FSTS move FP32 through memory (widen on load,
narrow RNE on store; a 4-byte window store is not a datagram — it
faults). Zig's f64 arithmetic is the implementation: IEEE requires
correctly-rounded +,−,×,÷,√, so bit-exactness costs nothing —
verified in ReleaseFast too, where the optimizer would be the first
suspect. FTOI truncates toward zero and saturates with V (NaN → 0
with V); the boundary case is exact because 2^63 is representable and
the largest f64 below it fits i64.

`sim6564 mandel` is the workload: mandel.asm iterates z² + c in the
near page (variables lived in zero page on the ancestor, and still
do), builds each row left-to-right so the 8-byte STA tails are
overwritten by the next column, and ships rows to the console with
hello.asm's retry discipline. The test replays the whole picture
against a host-f64 oracle — any misrounding anywhere in ~40k FP ops
is a visibly wrong character.

## joe v1 (post-v2.5 handoff item 3)

`src/joe.zig` compiles the sketch's pingpong subset to .asm text —
four passes, no IR, the near page as the frame. Design notes that
matter for extending it:

- **The runtime ABI is ping.asm's wiring, verbatim** (desc 0/1/2 =
  SQ/CQ/RX, timer SQ at slot 5, landing buffers with cookie = buffer
  address, AUTO_REARM black-hole timer with reserved cookie $77) —
  but parameterized: the compiler takes a `Layout` (origin, data base,
  timer PTT slot) so any number of instances can share a core, each in
  its own $1000 block.
- **Deployment is data: the `system` block.** `name = Actor(args) [on
  core]` in the source; an argument naming another instance is a
  capability, and the loader (`src/joe_run.zig`) allocates the PTT
  slot, aims it at the target's RX ring, and stages the window value
  as the addr param. `sim6564 joe <file.joe>` runs any system-bearing
  source — there are no per-program joe harnesses, by design. The
  loader also translates the machine's stop reason into system terms:
  every instance halted-or-parked with no faults is *quiescence*.
- **Wire format**: word0 low 16 bits = tag (declaration order,
  1-based), fields packed at their own alignment so none straddles a
  word; ≤ 8 bytes total rides TXR (one register datagram), larger
  stages at $2500 and rides SEND. The receive side can't tell.
- **The serve loop consumes transport acks invisibly** (tag 1/2
  completions that aren't the timer cookie) — the end-to-end argument
  is enforced by the dispatcher the compiler emits, not by programmer
  discipline.
- **`.from` is deliberately absent from v1**: a reply target is a
  capability in the receiver's PTT space, and the sender cannot name
  it. Surfacing `.from` is the capability-transfer question — it needs
  spec work, not compiler work. Reply routes are params for now.
- **`after N` leans on the harness**: per-send timeout values are
  still an open spec item (§10), so the contract exports
  `timer_period` and the harness wires it as the fabric's
  send_timeout. One `after` per serve until then.
- `let` errors as unsupported ON PURPOSE — park-point liveness is
  handoff item 4's experiment and should arrive as a measured change,
  not a freebie.

## joe Amendment 1: iteration (docs/joe-v1-ammendment-1.md)

The amendment's verdict — *`while` dies, `for` becomes replicated PAR,
`bounded` becomes checkable, `map` stays pure* — landed as follows:

- **`while` is a targeted compile error**, not an unknown keyword: "joe
  has no `while` (Amendment 1): unbounded iteration is a self-send
  loop, one park per slice." The replacement construct is real:
  **`send self`** resolves to a compiler-internal near slot holding a
  capability to the actor's own RX ring, staged by the loader like any
  other capability (`Result.self_slot`). The physics make A1.1 sound:
  same-core delivery is on-chip (fixed 4-cycle latency, no loss roll,
  machine.zig's `onchip` path), so a self-send loop needs no retry
  discipline — `crunch.joe` sums 1..1000 in 20 parked slices under the
  default 25%-loss fabric with zero losses.
- **`for` was already A1.2-shaped** (collection/range only, no mutation
  of the iteration space, no loop-carried accumulator in expressions) —
  no change needed; the grammar delta was satisfied on arrival.
- **`bounded` is enforced, not requested (A1.3).** The compiler now
  runs a cost accountant during emission: every line `Gen.w()` writes
  is charged its ISA-table cycles (mode-exact — the operand shapes the
  generator emits form a closed set, classified back to addressing
  modes and billed from the same table the machine bills from).
  Constant-extent `for` ranges multiply the once-emitted body into the
  bound; a group's count or a variable range marks the burst
  *data-dependent*. Each burst — init, and every handler body plus the
  serve loop's dispatch overhead — is then checked against the
  strictest watchdog any spawn site imposes on the actor:
  - bound computable and within budget → no declaration allowed
    (a gratuitous `bounded` is rejected);
  - bound computable and over budget → `bounded N` required, and
    rejected if N understates the computed body cost;
  - bound data-dependent → `bounded N` required and *trusted* — the
    runtime WDEX makes the watchdog the judge of data the analysis
    cannot see;
  - no watchdog anywhere → no budget exists, and any `bounded` is
    rejected ("nobody is counting").
  supervise.joe's Sleeper is the living example: its old `bounded 40`
  over five straight-line adds is now a *compile error* (arithmetic is
  checked), so the hang moved to where hangs still live — an honest-
  looking `bounded 64` over a loop whose extent is a variable the
  analysis cannot see. Same observable behavior (watchdog fault,
  `hung`, respawn, abandonment), but the lie is now about data.
- **The vector package (A1.4) and pure `map` (A1.5) ride with Tier 1**
  (handoff item 5) — they are surface syntax for a vector unit the
  machine does not have yet, and joe does not front-run silicon.

## The bank collapse, measured through joe (post-v2.5 handoff item 4, §1)

The §1 decision — every context switch is voluntary or fatal, so the
banked register file can collapse to one shared set, volatile across
parks — was measured, not assumed. Implementation notes:

- **The compiler is the register allocator.** joe codegen treats the
  clobber set (`LSTN`, `YLD`, `RECV`, `SEND`) as a full clobber of A,
  X, Y, SP and P, and spends registers freely *within* a burst: fused
  one-compare deliver test (`status<<8|tag` vs `#3`), word0 in Y only
  where an exit/timer path needs it, message tags compared down a
  ladder in A (sole unguarded case: no tag test — the wire is closed),
  sends composed in A, direct-operand arithmetic (`INC` for `+= 1`,
  `CMP #imm`/`CMP $slot`, `== 0` free off the Z flag).
- **The stack is not used after init — or before it.** Expression
  temporaries are static near-page slots (`_tmp0..3`, depth tracked at
  compile time, refused honestly past four). The compiled corpus
  contains zero stack operations, so SP requires nothing preserved,
  exactly as §1's clobber set demands. `machine.scorch_pattern` fills
  every register at every real park when `Config.scorch_parks` is on —
  the maximally hostile legal implementation — and the joe corpus runs
  cycle-identical under it (suite-asserted; CLI: `... scorch`).
- **Result: ring.joe 110 → 55.26 cy/pass, hand ring 60.** The
  pre-registered prediction was <70. Full table and the v2.6 verdict
  in docs/measurements.md.
- The **sole-case dispatch elision** is a deliberate semantic choice,
  recorded here: an actor with exactly one unguarded `case` treats
  every clean delivery as that message. The wire is closed (all
  senders compile from the same source), so one pattern is a total
  match; a mis-wired sender would be misparsed rather than dropped.
  If joe ever gains separately-compiled systems, this elision needs a
  linker-level revisit.
- The control-block near-page stripe (privileged, write-protected
  against the owning context: incarnation, exit link, watchdog base +
  ceiling) is the one new silicon mechanism the collapse requires — it
  rides with the v2.6 spec draft, not the simulator measurement.

## Stats and tracing

`Machine.stats`: instructions, context switches, sends, delivered, lost,
duplicated, timeouts, rejects, unroutable, CQ overflows, and the §7
counters dev_deliveries / dev_replies. `Config.trace` prints
scheduler/RBC/fabric events with cycle stamps to stderr — the demo
takes `trace` as its 4th CLI arg.

## Phase status (§10 of the spec)

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
  workloads all run, entirely from CQ feedback and the primitives of §5–§8
  — no ISA additions were needed beyond §5.4's supervision pair.
- **Peripheral row (spec §7, v2.3): complete.** Console, entropy, RTC and
  block devices as fabric endpoints; `sim6564 hello` and `sim6564 periph`
  drive them end to end from assembly; null cost verified against the
  frozen measurement table.
- **IO plane (spec §6.5, v2.4): complete.** Multi-die clusters with
  conservative windows, one host thread per die, bit-identical at any
  thread count; `sim6564 dies` spans Armstrong's ring across 16 dies on
  unmodified program bytes. Null cost verified again.
- **Measured claims** (`sim6564 ring` — Joe Armstrong's N-processes-in-a-ring
  challenge from Programming Erlang ch. 12, run as N banked contexts on one
  core passing a single-register TXR): **60 cycles per message pass** at
  steady state, receive-to-forward, scheduler and completion handling
  included, flat from 64×100 to 200×1000 passes. A "process" costs one
  41-byte register bank plus its near page; 200 of them fit on a core with
  room to spare. This is §2.2's "minimalism as a concurrency superpower"
  with a number attached, guarded by a <100-cycle regression test.
