# sim6564

Reference simulator for the **6564-Net** — a 64-bit silicon actor machine
descended from the 6502: five registers, a 4 KB near page, hardware queue
pairs, IPv6-native network addressing, and free-running concurrency.

- Architecture: [docs/6564-net-architecture-v2.md](docs/6564-net-architecture-v2.md)
- Implementation record: [docs/simulator.md](docs/simulator.md)

Built with **Zig 0.14.1**.

```sh
zig build test          # full suite: unit + assembled end-to-end programs
zig build run           # ping-pong actors across a 25%-lossy fabric
./zig-out/bin/sim6564 [seed] [loss_ppm4k] [rounds] [trace]
./zig-out/bin/sim6564 0xBEEF 3000 12      # 73% packet loss; still finishes
```

The demo runs two actors on two simulated cores joined by a fabric that
loses, delays, reorders and duplicates datagrams (deterministically, from the
seed). The ping actor implements an end-to-end reliable protocol — sequence
checking plus a retransmission timer built from the fabric itself (a send to
an unroutable prefix is a guaranteed timeout completion) — and completes its
rounds at any loss rate below total.

Everything decodes from one declarative ISA table (`src/isa.zig`): the
simulator, the assembler, and the disassembly of intent. Adding an
instruction is one line; a duplicate opcode is a compile error.
