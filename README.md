# sim6564

Reference simulator for the **6564-Net** — a 64-bit silicon actor machine
descended from the 6502: five registers, a 4 KB near page, hardware queue
pairs, IPv6-native network addressing, and free-running concurrency.

- Architecture: [docs/6564-net-architecture-v2.6.md](docs/6564-net-architecture-v2.6.md)
- Implementation record: [docs/simulator.md](docs/simulator.md)

Built with **Zig 0.14.1**.

```sh
zig build test          # full suite: unit + assembled end-to-end programs
zig build run           # ping-pong actors across a 25%-lossy fabric
./zig-out/bin/sim6564 [seed] [loss_ppm4k] [rounds] [trace]
./zig-out/bin/sim6564 0xBEEF 3000 12      # 73% packet loss; still finishes
./zig-out/bin/sim6564 supervise           # supervision tree demo
./zig-out/bin/sim6564 hello               # the machine says hello
./zig-out/bin/sim6564 run src/programs/asm/ring_node.asm   # any program runs itself
./zig-out/bin/sim6564 run src/programs/joe/ring.joe        # either language
```

The 6564 programs live in `src/programs/asm/*.asm` and
`src/programs/joe/*.joe` — and every one **carries its own deployment**.
A .joe file has its `system` block; a .asm file has the same thing as
assembler directives: its old "Harness contract" comment made
machine-readable (`.actor`, `.ring`, `.timer`, `.var`, a `.system`
block in joe's own grammar) and executed by one generic loader
(`src/asm_run.zig`). The fourteen per-program demo_*.zig harnesses that
once wired rings and PTT slots by hand are gone; the classic verbs
below are sugar over the same loader, and every conversion was verified
against its harness before the harness died — most of them
**bit-identical**, cycles and fabric stats alike. How to write one:
[docs/asm-guide.md](docs/asm-guide.md).

**pingpong** runs two actors on two simulated cores joined by a fabric that
loses, delays, reorders and duplicates datagrams (deterministically, from the
seed). The ping actor implements an end-to-end reliable protocol — sequence
checking plus a retransmission timer built from the fabric itself (a send to
an unroutable prefix is a guaranteed timeout completion, spec §6.3) — and
completes its rounds at any loss rate below total.

**pipeline** runs dataflow across `stages+2` cores (`sim6564 pipeline`):
each hop is stop-and-wait on application acks with sequence dedup, stages
ack on *ownership* so hops overlap, backpressure is the absence of an ack,
and shutdown is a poison-pill item with lame-duck draining — every item
arrives checksum-verified at any loss rate below total.

**scatter** fans a task out to 8 workers (`sim6564 scatter`), which
square it by shift-add multiply and reply; results converge on one
capacity-8 RX ring. The result is the ack: stragglers are simply re-asked
on timer ticks, and idempotent workers make duplicates harmless.

**ring** is Joe Armstrong's challenge (Programming Erlang, ch. 12): N
processes in a ring, a message around M times (`sim6564 ring 200 1000` =
200,000 passes). Processes are banked contexts, the message is one TXR
register-datagram, and a pass costs **60 cycles** at steady state —
scheduler, completion queue, and zero-cycle context switch included.

**bigbrother** floods one actor from 10,000 senders (`sim6564
bigbrother`): 55 cycles per absorbed message, every voice heard exactly
once, zero completion records lost — saturation is backpressure, not
corruption. **forkjoin** forks one message to 1,000 workers through a
LINK-chain-plus-hierarchy tree, relays it, and joins it back to one
aggregator in a 55,000-cycle makespan (`sim6564 forkjoin`) — run
entirely from the tree's own `.system` block, 2,010 declared instances.

**supervise** runs a one-for-one supervision tree on one core: exit links
post a dead worker's obituary to the supervisor's completion queue as an
ordinary completion record, and `SPWN` resurrects it with fresh registers
while its work survives in RAM — Erlang's supervisors, in silicon (spec
§5.4). One worker crashes (BRK); another *hangs*, spinning without yielding,
and only its watchdog burst budget can tell — the hang becomes an ordinary
fault with its own fault code. Per-child restart budgets run out; the
unreliable are abandoned, honestly.

**hello** and **periph** drive the peripheral row (spec §7): devices are
actors at mesh coordinates `$FF00..$FFFE`, reached by `SEND` through PTT
capabilities — no MMIO, no interrupts, no DMA engine, zero new opcodes.
`hello` prints through the console device; `periph` walks the whole row —
timestamps itself off the RTC, hex-prints an entropy draw, round-trips a
disk sector with verification, and prints its own cycle bill:

```
6564 PERIPHERAL BUS CHECK
ENTROPY 33FB3C626C1F610A
BLOCK OK
CYCLES 00000000000039A7
```

**joe** is the language (`sim6564 joe [file.joe]`; compiler in
`src/joe.zig`, sketch in `docs/joe-v1-sketch.md`): Go's clothes,
Erlang's soul, occam's discipline. `pingpong.joe` — an actor, a
`serve` loop, a fabric timer, and not one line of ack handling,
because joe has no syntax for transport acks — compiles to 6564
assembly (`sim6564 joec src/programs/joe/pingpong.joe Pinger` to read it)
and completes its rounds at 73% packet loss, sequence-checked, at
+10% code and +1% wall clock against the hand-written ping.asm.
Deployment is data: a `system` block in the source names instances
and their wiring — `ws = Worker[1000](ls)` declares a thousand
replicas, aligned to their lieutenants by the loader — and placement,
PTT capabilities, parameter staging and timers are all loader work:
any `.joe` file runs without a harness. The capstone is
`src/programs/joe/forkjoin.joe`: a 1,009-actor fork-join tree, every hop
acked through the tree because joe cannot see transport verdicts,
joining to the exact sum at 25% packet loss. The bank-collapse
experiment ran through this corpus and closed: registers are one
shared set, volatile across parks, and the compiler's burst-liveness
codegen took Armstrong's ring from 110 to **55 cycles a pass — under
the hand-written 60** — while the whole corpus runs cycle-identical
with every register *poisoned* at every park (`sim6564 joe
src/programs/joe/ring.joe 0x6564 1024 scorch`). A context is a near page,
a run-queue entry and a control block; nothing else survives, and
nothing compiled ever needed more. Amendment 1
(`docs/joe-v1-ammendment-1.md`) made the language smaller and the
promise larger: `while` is gone — unbounded work is a `send self`
loop, on-chip and lossless, one park per slice (`crunch.joe`) — and
`bounded` is *checked*: the compiler charges every emitted instruction
its ISA-table cycles, so an understated budget is a compile error and
the watchdog remains judge only of the data-dependent claims.
Amendment 2 makes bytes honest: **struple** — the memcmp-orderable
tuple format with twelve byte-identical implementations — is joe's
tuple encoding, and the joe/6564 codec is the **thirteenth**, driven
by the same language-neutral corpus, on the simulator, with every
register poisoned at every park. `pack key, ("users", id, "profile")`
pre-packs constants at compile time; `case Get(g) where g.key is
("users", ?id, ..rest)` dispatches on key *structure* — the constant
prefix is a word-compare against pre-packed bytes, so matching a
structured key costs what a tag compare costs, scaled by key length
(`keys.joe`). Skip is total in silicon: `.count()` walks every type
in the tower, including the four joe cannot decode.

**mandel** renders the Mandelbrot set in IEEE 754 double precision on
a 6502 descendant (`sim6564 mandel`): Tier 0 scalar FP lives on the
extended opcode page behind prefix `$42` — WDM, the byte the 65816
reserved for expansion and never spent. FP64 in the accumulator, IEEE
round-to-nearest-even, no FTZ, no fusion; the test asserts all 22 rows
character-for-character against an independent host computation, so
one misrounded result among ~40,000 FP ops is a visibly wrong pixel.
A picture as a determinism test.

**dies** runs Armstrong's ring across up to 16 whole dies joined by the
IO plane (spec §6.5) — each die a complete machine on its own host
thread, exchanging datagrams at conservative-horizon barriers, **bit-
identical to the sequential run at any thread count**. The ring program
is byte-for-byte the single-die one: remoteness is one route byte in a
PTT entry. `sim6564 dies 16 100 10 2000` keeps all 16 host threads hot
with die-local rings — **6.1× wall-clock over sequential** in
ReleaseFast with `spread`/`vcache`/`freq` L3-domain pinning
(`src/topology.zig`; placement changes seconds, never bits).

**net** runs the ring across two OS **processes** joined by a real TCP
socket (`sim6564 net listen 6564` + `sim6564 net connect 127.0.0.1
6564`): the IO plane's window barriers cross the wire as frames of
virtual-time-stamped datagrams, so the federation replays
bit-identically from its seeds regardless of real network timing. The
wall clock never enters the machine — TCP is just a slow backplane.

**web** is the capstone: `http_get.asm` — 6502-descendant assembly —
speaks HTTP/1.1 through the `net` device (a raw byte pipe, spec §7.4)
and prints a real web page on its teletype (`sim6564 web` fetches
example.com; a few hundred instructions and a clean halt, the exact
count set by the outside world's chunking). The protocol lives in 6564
code: spec §7.5's rule is that silicon is an optimization, never an
interface — any device contract must be implementable by an ordinary
actor, so HTTP/WebSocket/TLS engines can ship as gates or as polyfill
and no client can tell.

Everything decodes from one declarative ISA table (`src/isa.zig`): the
simulator, the assembler, and the disassembly of intent. Adding an
instruction is one line; a duplicate opcode is a compile error.
