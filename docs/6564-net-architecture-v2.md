# The 6564-Net Architecture

**A 64-bit silicon actor machine: minimalist microarchitecture with native network addressing, hardware queue pairs, and free-running concurrency.**

*Draft v2 — Entrained AI Research Institute — July 2026*

---

## 1. Executive Summary

The 6564-Net is a 64-bit microprocessor architecture that treats the network as memory and the actor as the fundamental unit of execution. It descends philosophically from the MOS 6502 — small architectural state, predictable timing, honest semantics — and scales that philosophy to a world of distributed, message-passing computation.

Modern architectures pay enormous taxes that are invisible only because they are universal: OS context switches measured in microseconds, network stacks that traverse a dozen software layers per packet, and synchronous I/O models that stall cores waiting on events the silicon could have handled itself. The 6564-Net eliminates these layers by baking three things directly into the instruction set:

1. **Network addressing as memory addressing.** Remote destinations are reached through ordinary 64-bit pointers via a hardware translation window onto IPv6 space.
2. **Queue pairs in silicon.** All I/O flows through hardware-managed submission and completion rings — the io_uring / NVMe model, implemented in gates rather than kernel code.
3. **Free concurrency.** The architectural state is five 64-bit registers. Full hardware contexts cost 40 bytes each, making banked, zero-cycle context switching not an aspiration but an arithmetic fact.

The result is a **silicon actor machine**: each hardware context is an actor with a mailbox (its receive ring), an address (its IPv6-mapped window), and asynchronous message semantics enforced by the ISA itself. The 6564-Net is the native substrate for actor-model operating systems — it executes in hardware what systems like MiOS implement in software.

---

## 2. Design Philosophy

### 2.1 The 6502 Lineage, Taken Seriously

The 6502's enduring virtues were never its register count. They were:

- **Tiny architectural state**, making interrupts and task switches cheap.
- **Zero page** — a 256-byte region with short-encoding addressing that functioned as a large pseudo-register file.
- **Predictable, countable cycle timing**, enabling software with hard real-time guarantees.
- **Honest semantics** — no hidden microarchitectural state lying to the programmer.

The 6564-Net preserves all four, scaled to 64 bits. Where a design decision arises, the tiebreaker is always: *simple silicon, honest semantics, complexity pushed to software where software can see it.*

### 2.2 Minimalism as a Concurrency Superpower

This is the load-bearing insight of the architecture. Total architectural state per thread of execution:

| Register | Width | Purpose |
|---|---|---|
| A | 64-bit | Accumulator |
| X | 64-bit | Index |
| Y | 64-bit | Index |
| SP | 64-bit | Stack pointer |
| IP | 64-bit | Instruction pointer |
| P | 8-bit | Status flags |

**Total: 41 bytes.** A conventional x86-64 context (with vector state) runs to kilobytes; even a lean RISC-V context is hundreds of bytes. At 41 bytes, a modest register file of 16 KB holds ~400 complete hardware contexts. Context switching becomes bank selection: a mux, not a memcpy.

This is the XMOS xCORE / barrel-processor lineage, and it is what makes the rest of the architecture honest. When an I/O instruction says "the core proceeds immediately to the next runnable continuation," that is a literal single-cycle bank switch, not a euphemism for a scheduler invocation.

---

## 3. Register and Memory Architecture

### 3.1 The Near Page

The bottom 4 KB of each context's address space is the **near page** — the 64-bit descendant of zero page. Near-page addresses encode in a single byte-pair operand, and the near page is held in dedicated low-latency storage adjacent to the register banks.

The near page is not merely fast scratch. It is where the architecture keeps its *nouns*:

- **Ring buffer descriptors** (submission and completion queue heads, tails, base pointers, capability tokens)
- **Continuation slots** (pending code pointers for the hardware scheduler)
- **Hot pointers and loop state**

Because descriptors live at architecturally defined near-page offsets, the queue and continuation instructions (`LSTN`, `CONT`, `SEND`) take one-byte descriptor operands. Instruction density stays 6502-tight even though the machine is 64-bit.

### 3.2 The Network Window: 64-bit Pointers, 128-bit Reach

All architectural pointers are 64 bits. There are no 128-bit registers.

The upper region of the address space is the **network window**. When the high-order bits of an address select the window, the next field indexes the **Prefix Translation Table (PTT)** — a small, TLB-like hardware structure mapping window slots to IPv6 prefixes:

```
63           56 55        40 39                                0
┌──────────────┬────────────┬───────────────────────────────────┐
│ 0xFF (window)│  PTT index │   offset within remote region     │
└──────────────┴────────────┴───────────────────────────────────┘
```

Each PTT entry holds:

- A 128-bit IPv6 destination prefix
- Access rights (read / write / send)
- A **capability token** (§6)
- Routing hints (local core, on-die mesh, off-chip NIC)

Consequences:

- **Uniform syntax.** A store to a local buffer, a neighboring core, or a machine on another continent is the same instruction with a different pointer.
- **Local traffic never touches a network stack.** The PTT resolves on-die destinations to mesh routes; the IPv6 framing exists only when packets actually leave the chip.
- **The 6502 spirit survives.** Pointer arithmetic, indexing via X/Y, and indirect addressing all work unchanged against remote regions.

Loading the PTT is a privileged operation. Software above the ISA (the OS, or a capability kernel) decides what the world looks like; the silicon merely enforces it.

---

## 4. Hardware Queue Pairs

All asynchronous I/O flows through **queue pairs**: a submission ring (SQ) and a completion ring (CQ), managed entirely by hardware. This is the io_uring / NVMe model — proven at the software and device level — moved into the core.

### 4.1 Ring Buffer Controllers

Each queue pair is owned by an autonomous Ring Buffer Controller (RBC):

- **Automatic pointer wrapping.** Head and tail advance and wrap in hardware; software never computes a modulus.
- **Doorbell-free submission.** Because descriptors live in the near page, the RBC snoops descriptor writes directly; posting to an SQ is a single near-page store.
- **Threshold events.** Empty, full, and watermark conditions raise events into the hardware scheduler (§5) — they wake continuations rather than firing traditional interrupts.

### 4.2 Completion Records

Every asynchronous operation eventually posts exactly one **completion record** to the relevant CQ:

```
┌────────────┬──────────┬────────────┬──────────────────────┐
│ op tag     │ status   │ byte count │ user cookie (64-bit) │
└────────────┴──────────┴────────────┴──────────────────────┘
```

Status codes distinguish success, truncation, remote reject (capability failure), and timeout. **There is no other channel for I/O status.** No sticky error flags, no exceptions from network conditions — the CQ is the single source of truth, and software consumes it at its leisure.

---

## 5. Execution Model: Continuations and the Hardware Scheduler

### 5.1 Contexts as Actors

A **context** is one banked register set plus its near page. Each context owns at least one queue pair and one PTT-visible address — which makes each context, precisely, an actor: private state, an inbox, an address, and asynchronous sends.

### 5.2 The Continuation Queue

The core maintains a hardware run queue of **continuations** — (context, IP) pairs ready to execute. The scheduling primitives:

- **`CONT addr`** — push a continuation onto the run queue.
- **`LSTN desc`** — park the current context until the descriptor's ring has data (or hits its watermark), then resume at the following instruction. Parking is free: the context simply leaves the run queue.
- **`YLD`** — voluntarily rotate to the next runnable continuation.

When any instruction would block — `LSTN` on an empty ring, `SEND` on a full SQ — the core bank-switches to the next runnable continuation in a single cycle. A 6564-Net core with pending work never stalls on I/O. There is no busy loop anywhere in the model; the concept does not exist.

### 5.3 Fairness and Real Time

The scheduler is round-robin by default with an optional per-context priority nibble. Because contexts are cheap and switches are single-cycle, real-time guarantees reduce to counting cycles within a context — the same discipline 6502 programmers used, recovered at 64 bits.

---

## 6. Delivery Semantics, Ownership, and Security

The architecture is honest about the network. These three subsections are normative.

### 6.1 Delivery: Unreliable, with Truthful Completions

The ISA-level guarantee for remote operations is **unreliable datagram delivery with mandatory completion reporting**:

- A `SEND` may be lost, reordered, or rejected by the remote end.
- The local CQ *always* receives a completion record: success (remote RBC acknowledged), reject, or timeout.
- Per-flow ordering is preserved for traffic through a single PTT entry on an uncongested path, but is not architecturally guaranteed end-to-end.

Reliability, retransmission, and flow control are software's job, built from CQ feedback — exactly as TCP is built on IP. The silicon stays simple; the semantics never lie.

### 6.2 Buffer Ownership

Every transmit descriptor carries an **ownership bit**, set by hardware when a `SEND` is accepted and cleared when its completion record posts.

- While the ownership bit is set, the buffer belongs to the DMA engine. **A store to an in-flight buffer has undefined effect on the transmitted data** (the local store itself completes normally).
- The completion record is the release fence: after software observes it, the buffer is unambiguously software-owned again.

One bit, one rule, no ambiguity. Software wanting fire-and-forget semantics copies into a transmit pool first; software wanting zero-copy respects the bit.

### 6.3 Timers: the Fabric as Clock

The ISA deliberately has no timer instruction, and none is needed. A `SEND` or `TXR` through an **unroutable PTT prefix** moves no data and generates no reject — the only thing that can ever speak for it is its mandatory timeout completion, which arrives exactly `send_timeout` cycles after submission. Software therefore builds retransmission timers, heartbeats, and watchdogs from the fabric's honesty alone:

- A PTT entry whose prefix routes nowhere is a **black-hole capability**: sends through it vanish silently and complete with `timeout`, always.
- Privileged software SHOULD provision each context that runs an end-to-end protocol with one black-hole PTT entry, by convention in a well-known slot.
- The timeout completion's cookie distinguishes timer ticks from data traffic; a persistent chain (re-arm on every tick) yields a steady clock.

This was discovered, not designed: simulation showed that the "send acknowledged, reply lost" case leaves a sender with nothing outstanding and nothing to wake on — unrecoverable without a timer. The fix required no new silicon, only the semantics §6.1 already promised. Per-send timeout values in the transmit descriptor remain future work.

### 6.4 Capabilities

Any memory reachable from a network is memory that must defend itself. The 6564-Net adopts the RDMA answer, enforced in hardware:

- Every PTT entry and every ring descriptor exposed to remote access carries a **64-bit capability token**.
- Inbound operations must present a matching token; the RBC checks it before any byte moves. Failures post a reject completion to *both* ends and move no data.
- Tokens are minted and revoked by privileged software. Revocation is immediate: clear the descriptor field.

This composes naturally with capability-based operating systems — a PTT entry *is* a capability in the object-capability sense, and the OS's capability graph maps directly onto silicon-enforced reachability.

---

## 7. Instruction Set Sketch (I/O and Concurrency Subset)

| Mnemonic | Description | Syntax |
|---|---|---|
| `TXR` | Transmit register: post a single-register datagram via a PTT-mapped pointer. Completion record still posts to the CQ. | `TXR (ptr), A` |
| `SEND` | Asynchronous block transfer: post a descriptor to an SQ; hardware DMA streams the buffer. Sets ownership bit. | `SEND desc` |
| `RECV` | Post a receive buffer to a descriptor's ring, granting the RBC landing space for inbound data. | `RECV desc` |
| `LSTN` | Park this context until the descriptor's ring is non-empty (or hits watermark). | `LSTN desc` |
| `CONT` | Push a continuation onto the hardware run queue. | `CONT addr` |
| `YLD` | Yield to the next runnable continuation. | `YLD` |
| `CQPOP` | Pop the next completion record into A (tag/status) and X (cookie); Z flag set if CQ empty. | `CQPOP desc` |
| `CAPLD` | Privileged: load a PTT entry (prefix, rights, capability token). | `CAPLD slot, (ptr)` |

Descriptor operands (`desc`) are one-byte near-page offsets. The general-purpose instruction set (loads, stores, arithmetic, branches) follows the 6502 pattern language — including indexed and indirect modes — widened to 64 bits, and applies uniformly to local and network-window addresses.

### Encoding Note

Instructions remain byte-granular and variable-length in the 6502 tradition: one-byte opcodes, with operands sized by addressing mode. Near-page modes keep the hot path (queue ops, continuation ops) at 2–3 bytes per instruction. Code density is a stated goal: instruction fetch is a bandwidth consumer like any other, and a message-passing machine should not spend its bandwidth describing itself.

---

## 8. Prior Art and Positioning

The 6564-Net is deliberately positioned within a lineage, inheriting proven ideas and their hard-won lessons:

- **INMOS Transputer / occam** — the closest ancestor. `LSTN` is occam's channel input; the continuation queue is the Transputer's hardware process list. The Transputer's lesson: the programming model must be first-class, not bolted on. Here, the actor model is the ISA.
- **XMOS xCORE** — living proof that banked hardware threads with event-driven I/O deliver hard real-time without interrupts.
- **Cray T3E E-registers** — remote memory accessed through register-mapped windows; direct ancestor of the network window.
- **MIT J-Machine** — message-driven processors with hardware dispatch on message arrival.
- **SpiNNaker** — a million-core machine built on small cores and unreliable multicast messaging; validation that "unreliable, honest, and fast" scales.
- **io_uring / NVMe queue pairs** — the SQ/CQ discipline, proven at OS and device level, here moved into the core.
- **RDMA (rkeys)** — the capability-token model for network-exposed memory.

The synthesis is the novelty: no prior architecture combines 6502-grade architectural minimalism, IPv6-native global addressing, and hardware queue-pair semantics in a single ISA whose unit of execution is the actor.

---

## 9. Simulator Plan

The reference simulator validates the ISA and — critically — exercises the failure semantics of §6 from day one. Implementation language: **Zig**, for comptime-generated opcode dispatch tables, explicit memory control, and freedom from hidden allocation.

> **Status (July 2026):** Phases 1 and 2 are implemented; Phase 3 has begun. Concrete layouts, v0.1 simplifications, and lessons already fed back from implementation are recorded in [simulator.md](simulator.md).

### Phase 1 — Deterministic Core

- Cycle-stepped virtual clock; every run fully deterministic from a seed.
- 64-bit memory model with near-page semantics and banked contexts.
- Opcode decoder generated at comptime from a declarative ISA table (single source of truth for simulator, assembler, and documentation).
- Hardware scheduler, continuation queue, and single-core queue pairs.

### Phase 2 — Virtual Network Mesh

- Multiple simulated cores, each with PTT entries mapping to peers.
- **Seeded fault injection is mandatory, not optional**: configurable latency distributions, packet loss, reordering, and duplication on every inter-core path. The delivery semantics of §6.1 must be *exercised*, not assumed.
- Deterministic replay: any observed failure reproduces exactly from its seed, making concurrency bugs debuggable rather than anecdotal.

### Phase 3 — Actor Workloads

- Port representative actor-model workloads (supervision trees, pipeline dataflow, scatter-gather) to validate that the ISA's primitives compose into a real programming model.
- Measure the claims: context-switch cost, message latency in cycles, core utilization under I/O-heavy load versus a conventional interrupt-driven model.

---

## 10. Open Questions

Recorded honestly, for future revisions:

1. **PTT size and miss handling** — fixed small table with software reload (TLB-style trap), or hardware-walked prefix structure?
2. **Inbound flow control** — what happens architecturally when a remote peer floods a full receive ring? Current position: drop and reject-complete (honest), but watermark-based backpressure hints are worth exploring.
3. **Multi-core cache/coherence stance** — the actor model argues for *no* coherent shared memory between contexts (message passing only). This is philosophically clean and silicon-cheap, but needs a stated position on shared read-only code pages.
4. **Privilege model** — how minimal can the privileged layer be if PTT entries are the only capability boundary? A two-level model (capability kernel / actors) may suffice.
5. **Interrupt legacy** — is there any residual need for classical interrupts at all, or do threshold events into the continuation queue subsume them entirely?

6. **Timers** — *resolved in this revision.* The black-hole-prefix idiom (§6.3, "the fabric as clock") is now normative; no first-class timer ring. Still open within it: per-send timeout values in the transmit descriptor, and whether a well-known black-hole PTT slot number should be architecturally fixed rather than conventional.

---

*The 6502 proved that a small, honest machine could carry a revolution. The 6564-Net is a wager that the same virtues — tiny state, predictable behavior, semantics that never lie — are exactly what a planet-scale mesh of communicating actors has been waiting for.*
