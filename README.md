# sim6564

Reference simulator for the **6564-Net** — a 64-bit silicon actor machine
descended from the 6502: five registers, a 4 KB near page, hardware queue
pairs, IPv6-native network addressing, and free-running concurrency.

- Architecture: [docs/6564-net-architecture-v2.5.md](docs/6564-net-architecture-v2.5.md)
- Implementation record: [docs/simulator.md](docs/simulator.md)

Built with **Zig 0.14.1**.

```sh
zig build test          # full suite: unit + assembled end-to-end programs
zig build run           # ping-pong actors across a 25%-lossy fabric
./zig-out/bin/sim6564 [seed] [loss_ppm4k] [rounds] [trace]
./zig-out/bin/sim6564 0xBEEF 3000 12      # 73% packet loss; still finishes
./zig-out/bin/sim6564 supervise           # supervision tree demo
./zig-out/bin/sim6564 hello               # the machine says hello
```

The 6564 programs themselves live in `src/programs/*.asm`.

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

**scatter** fans a task out to up to 8 workers (`sim6564 scatter`), which
square it by shift-add multiply and reply; results converge on one
capacity-8 RX ring. The result is the ack: stragglers are simply re-asked
on timer ticks, and idempotent workers make duplicates harmless.

**ring** is Joe Armstrong's challenge (Programming Erlang, ch. 12): N
processes in a ring, a message around M times (`sim6564 ring 200 1000` =
200,000 passes). Processes are banked contexts, the message is one TXR
register-datagram, and a pass costs **66 cycles** at steady state —
scheduler, completion queue, and zero-cycle context switch included.

**bigbrother** floods one actor from 10,000 senders (`sim6564
bigbrother`): 61 cycles per absorbed message, every voice heard exactly
once, zero completion records lost — saturation is backpressure, not
corruption. **forkjoin** forks one message to 1,000 workers through a
LINK-chain-plus-hierarchy tree, relays it, and joins it back to one
aggregator in a 61,000-cycle makespan (`sim6564 forkjoin`).

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
CYCLES 0000000000003A51
```

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
example.com; 784 instructions, clean halt). The protocol lives in 6564
code: spec §7.5's rule is that silicon is an optimization, never an
interface — any device contract must be implementable by an ordinary
actor, so HTTP/WebSocket/TLS engines can ship as gates or as polyfill
and no client can tell.

Everything decodes from one declarative ISA table (`src/isa.zig`): the
simulator, the assembler, and the disassembly of intent. Adding an
instruction is one line; a duplicate opcode is a compile error.
