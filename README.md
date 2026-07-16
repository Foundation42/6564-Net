# sim6564

Reference simulator for the **6564-Net** — a 64-bit silicon actor machine
descended from the 6502: five registers, a 4 KB near page, hardware queue
pairs, IPv6-native network addressing, and free-running concurrency.

- Architecture: [docs/6564-net-architecture-v2.2.md](docs/6564-net-architecture-v2.2.md)
- Implementation record: [docs/simulator.md](docs/simulator.md)

Built with **Zig 0.14.1**.

```sh
zig build test          # full suite: unit + assembled end-to-end programs
zig build run           # ping-pong actors across a 25%-lossy fabric
./zig-out/bin/sim6564 [seed] [loss_ppm4k] [rounds] [trace]
./zig-out/bin/sim6564 0xBEEF 3000 12      # 73% packet loss; still finishes
./zig-out/bin/sim6564 supervise           # supervision tree demo
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

**supervise** runs a one-for-one supervision tree on one core: exit links
post a dead worker's obituary to the supervisor's completion queue as an
ordinary completion record, and `SPWN` resurrects it with fresh registers
while its work survives in RAM — Erlang's supervisors, in silicon (spec
§5.4). One worker crashes (BRK); another *hangs*, spinning without yielding,
and only its watchdog burst budget can tell — the hang becomes an ordinary
fault with its own fault code. Per-child restart budgets run out; the
unreliable are abandoned, honestly.

Everything decodes from one declarative ISA table (`src/isa.zig`): the
simulator, the assembler, and the disassembly of intent. Adding an
instruction is one line; a duplicate opcode is a compile error.
