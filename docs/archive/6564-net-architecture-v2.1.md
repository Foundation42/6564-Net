# The 6564-Net Architecture

**A 64-bit silicon actor machine: minimalist microarchitecture with native network addressing, hardware queue pairs, and free-running concurrency.**

*Draft v2.1 — Entrained AI Research Institute — July 2026*

> **Changes from v2.** This revision folds back the findings of sim6564 v0.1
> (see the companion implementation record). New: §5.4 Supervision and the
> Watchdog; §6.3 Timers: the Fabric as Clock; the copies-not-messages rule in
> §6.1; the slot-reuse warning in §6.2; the `SPWN` instruction; measured
> numbers in §2.2 and §9. Open questions 3 and 7 are resolved; the open
> questions list is revised accordingly. Erlang/OTP joins the prior art,
> where it always belonged.

---

## 1. Executive Summary

The 6564-Net is a 64-bit microprocessor architecture that treats the network as memory and the actor as the fundamental unit of execution. It descends philosophically from the MOS 6502 — small architectural state, predictable timing, honest semantics — and scales that philosophy to a world of distributed, message-passing computation.

Modern architectures pay enormous taxes that are invisible only because they are universal: OS context switches measured in microseconds, network stacks that traverse a dozen software layers per packet, and synchronous I/O models that stall cores waiting on events the silicon could have handled itself. The 6564-Net eliminates these layers by baking three things directly into the instruction set:

1. **Network addressing as memory addressing.** Remote destinations are reached through ordinary 64-bit pointers via a hardware translation window onto IPv6 space.
2. **Queue pairs in silicon.** All I/O flows through hardware-managed submission and completion rings — the io_uring / NVMe model, implemented in gates rather than kernel code.
3. **Free concurrency.** The architectural state is five 64-bit registers. Full hardware contexts cost 41 bytes each, making banked, zero-cycle context switching not an aspiration but an arithmetic fact.

The result is a **silicon actor machine**: each hardware context is an actor with a mailbox (its receive ring), an address (its IPv6-mapped window), asynchronous message semantics, and — as of this revision — hardware-enforced supervision and fault isolation. The 6564-Net is the native substrate for actor-model operating systems: it executes in hardware what systems like MiOS implement in software, and what Erlang/OTP proved in production.

These claims are no longer only claims. The reference simulator implements every phase of §9, and the measured cost of a full receive-to-forward message pass between hardware actors is **66 cycles** (§2.2).

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

**Measured.** The reference simulator runs Armstrong's N-processes-in-a-ring challenge (*Programming Erlang*, ch. 12) as N banked contexts on one core passing a single-register `TXR`: **66 cycles per message pass** at steady state, receive-to-forward, scheduler and completion handling included, flat from 64 contexts × 100 passes to 200 × 1000. A "process" costs one 41-byte register bank plus its near page; 200 fit on a core with room to spare. The figure is guarded by a <100-cycle regression test.

---

## 3. Register and Memory Architecture

### 3.1 The Near Page

The bottom 4 KB of each context's address space is the **near page** — the 64-bit descendant of zero page. Near-page addresses encode in a single byte-pair operand, and the near page is held in dedicated low-latency storage adjacent to the register banks.

The near page is not merely fast scratch. It is where the architecture keeps its *nouns*:

- **Ring buffer descriptors** (submission and completion queue heads, tails, base pointers, capability tokens)
- **Continuation slots** (pending code pointers for the hardware scheduler)
- **Hot pointers and loop state**

Because descriptors live at architecturally defined near-page offsets, the queue and continuation instructions (`LSTN`, `CONT`, `SEND`) take one-byte descriptor operands. Instruction density stays 6502-tight even though the machine is 64-bit.

The near page is architecturally **private to its context** — the one region of memory whose isolation the hardware enforces unconditionally (see §10, resolved question 3).

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
- A **capability token** (§6.4)
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

- **Automatic pointer wrapping.** Head and tail are free-running counters; hardware masks against the (power-of-two) capacity. Software never computes a modulus; `count = tail − head`, full at `count == capacity`.
- **Doorbell-free submission.** Because descriptors live in the near page, the RBC snoops descriptor writes directly; posting to an SQ is a single near-page store.
- **Threshold events.** Empty, full, and watermark conditions raise events into the hardware scheduler (§5) — they wake continuations rather than firing traditional interrupts.

### 4.2 Completion Records

Every asynchronous operation eventually posts exactly one **completion record** to the relevant CQ:

```
┌────────────┬──────────┬────────────┬──────────────────────┐
│ op tag     │ status   │ byte count │ user cookie (64-bit) │
└────────────┴──────────┴────────────┴──────────────────────┘
```

Status codes distinguish success, truncation, remote reject (capability failure), no-buffer reject, and timeout. **There is no other channel for I/O status.** No sticky error flags, no exceptions from network conditions — the CQ is the single source of truth, and software consumes it at its leisure.

---

## 5. Execution Model: Continuations and the Hardware Scheduler

### 5.1 Contexts as Actors

A **context** is one banked register set plus its near page. Each context owns at least one queue pair and one PTT-visible address — which makes each context, precisely, an actor: private state, an inbox, an address, and asynchronous sends. Section 5.4 completes the correspondence: actors can also be *supervised, restarted, and bounded*.

### 5.2 The Continuation Queue

The core maintains a hardware run queue of **continuations** — (context, incarnation, IP) triples ready to execute. The scheduling primitives:

- **`CONT addr`** — push a continuation onto the run queue.
- **`LSTN desc`** — park the current context until the descriptor's ring has data (or hits its watermark), then resume at the following instruction. Parking is free: the context simply leaves the run queue.
- **`YLD`** — voluntarily rotate to the next runnable continuation.

When any instruction would block — `LSTN` on an empty ring, `SEND` on a full SQ — the core bank-switches to the next runnable continuation in a single cycle. A 6564-Net core with pending work never stalls on I/O. There is no busy loop anywhere in the model; the concept does not exist.

### 5.3 Fairness and Real Time

The scheduler is round-robin by default with an optional per-context priority nibble. Because contexts are cheap and switches are single-cycle, real-time guarantees reduce to counting cycles within a context — the same discipline 6502 programmers used, recovered at 64 bits.

### 5.4 Supervision and the Watchdog

Actors fail. The architecture makes failure *observable, attributable, and recoverable* with three small mechanisms — the hardware skeleton of an OTP-style supervision tree.

**Exit links.** Each context may carry an exit link: a (supervisor context, CQ slot) pair, set by privileged software. On halt or fault, hardware posts an **exit completion record** to the supervisor's designated CQ — tag `exit`, status carrying the halt/fault code, cookie carrying the (context id, incarnation) of the deceased. Death is a message, delivered through the same CQ machinery as everything else.

**`SPWN` — restart.** `SPWN nblk` (near-page operand; `nblk,X` for indexed spawn-block tables) points at a 32-byte **spawn block** — `{target context, entry IP, stack pointer, argument}` — one of the architecture's near-page nouns, like a ring descriptor. Hardware resets the target's registers, loads SP from the block, delivers the argument in A (per-actor configuration typically travels as a pointer to a config block), increments the target's **incarnation counter**, and queues a continuation at the entry IP. The target's near page and exit link **survive** the restart — identity and supervision persist across lives. Run-queue entries carry the incarnation number, so continuations belonging to a dead life are skipped at dispatch: a restarted actor cannot be haunted by its predecessor's pending work. `SPWN` of self, or of an out-of-range context, faults the *spawner*.

**The watchdog burst budget.** Exit links catch actors that die; they cannot catch actors that *hang*. A context spinning in a pure compute loop under cooperative scheduling starves its whole core — including the supervisor that would otherwise restart it. The remedy is one comparator: each context may carry a **burst budget** in cycles (0 = unbounded), set by privileged software and surviving `SPWN`. The check runs between instructions; a context that exceeds its budget within one scheduling burst faults with code `watchdog`, and its exit link fires like any other fault. Instructions remain atomic — the trip lands after the instruction that crossed the line. The hang becomes an ordinary, supervisable death.

Exit links and `SPWN` are same-core mechanisms; cross-core supervision is a software protocol built from ordinary messages — which is as it should be, since cross-core links would reintroduce synchronous trust across an unreliable fabric.

---

## 6. Delivery Semantics, Ownership, Timers, and Security

The architecture is honest about the network. These four subsections are normative.

### 6.1 Delivery: Unreliable, with Truthful Completions

The ISA-level guarantee for remote operations is **unreliable datagram delivery with mandatory completion reporting**:

- A `SEND` may be lost, reordered, duplicated in flight, or rejected by the remote end.
- The local CQ *always* receives a completion record: success (remote RBC acknowledged), reject, or timeout.
- Per-flow ordering is preserved for traffic through a single PTT entry on an uncongested path, but is not architecturally guaranteed end-to-end.

**Completion records describe the fate of *copies*, not of *messages*; end-to-end message identity is software's responsibility.** In particular, when a datagram is duplicated in flight, each copy earns its own truthful report, and a late copy's reject (e.g. `no_buffer`) may arrive before — or instead of being reconciled with — an earlier copy's `ok`. A sender may therefore be told "rejected" about a message that was, in the end-to-end sense, delivered. Each report is true of one copy; only software can speak about the message.

Reliability, retransmission, and flow control are software's job, built from CQ feedback — exactly as TCP is built on IP. Implementation experience confirms the classic end-to-end argument at ISA scale: transport acknowledgments are useful to applications for exactly one thing, buffer ownership release (§6.2); protocol correctness must rest on end-to-end evidence and timers (§6.3). The silicon stays simple; the semantics never lie.

### 6.2 Buffer Ownership

Every transmit descriptor carries an **ownership bit**, set by hardware when a `SEND` is accepted and cleared when its completion record posts.

- While the ownership bit is set, the buffer belongs to the DMA engine. **A store to an in-flight buffer has undefined effect on the transmitted data** (the local store itself completes normally).
- The completion record is the release fence: after software observes it, the buffer is unambiguously software-owned again.

One bit, one rule, no ambiguity. Software wanting fire-and-forget semantics copies into a transmit pool first; software wanting zero-copy respects the bit.

**Warning — slot reuse.** The ownership clear is applied to the descriptor location captured at accept time. Software that reuses an SQ slot before its previous operation's completion has posted is touching in-flight state: the eventual clear may land on the reused entry. This is the undefined-effect clause above, made concrete; it will bite on real silicon exactly as it does in simulation. Do not reuse a slot until its completion is observed.

A second consequence of hardware-managed landing: **delivery consumes the receive buffer regardless of whether software wants the payload.** A receiver that inspects a delivered datagram and discards it (a stale duplicate, say) must still re-post its landing buffer; accept/reject is the application's decision, but consumption already happened in hardware. The robust idiom is to repost on every `ok` delivery completion, wanted or not.

### 6.3 Timers: the Fabric as Clock

The ISA defines no timer peripheral, and needs none. The mandatory-completion guarantee of §6.1 *is* a clock:

**A `SEND` addressed through an unroutable PTT entry is the architectural timer primitive.** The datagram vanishes; the timeout completion record arrives on the local CQ exactly `send_timeout` cycles after acceptance. Software arms a timer by sending into a black hole and disarms it by ignoring the completion when it lands.

This is normative because it is load-bearing: over an unreliable fabric, the "request acknowledged, reply lost" case leaves a correct sender with nothing outstanding and nothing ever arriving — an unrecoverable park unless something wakes it. The fabric's honesty about its own timeouts is that something. Retransmission timers, retry-with-delay loops, and watch-timers for lame-duck shutdown phases all reduce to this one idiom, at zero silicon cost.

Open details (§10): whether `send_timeout` is per-send, per-PTT-entry, or global; and whether a standardized black-hole PTT slot should be architecturally reserved.

### 6.4 Capabilities

Any memory reachable from a network is memory that must defend itself. The 6564-Net adopts the RDMA answer, enforced in hardware:

- Every PTT entry and every ring descriptor exposed to remote access carries a **64-bit capability token**.
- Inbound operations must present a matching token; the RBC checks it before any byte moves. Failures post a reject completion to *both* ends and move no data.
- Tokens are minted and revoked by privileged software. Revocation is immediate: clear the descriptor field.

This composes naturally with capability-based operating systems — a PTT entry *is* a capability in the object-capability sense, and the OS's capability graph maps directly onto silicon-enforced reachability.

Note the limit of hardware's protection: tokens and rights guard *reachability*, not *layout*. Overlapping ring storage in RAM is a software contract violation the silicon cannot detect; memory maps remain the sharp edge they have always been.

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
| `CQPOP` | Pop the next completion record into A (tag/status/count) and X (cookie); Z flag set if CQ empty. | `CQPOP desc` |
| `SPWN` | Reset and restart a context from a near-page spawn block {ctx, entry, SP, arg→A} (§5.4): registers cleared, incarnation bumped, continuation queued. Near page and exit link survive. | `SPWN nblk` / `SPWN nblk,X` |
| `CAPLD` | Privileged: load a PTT entry (prefix, rights, capability token). | `CAPLD slot, (ptr)` |

Descriptor operands (`desc`) are one-byte near-page offsets. The general-purpose instruction set (loads, stores, arithmetic, branches) follows the 6502 pattern language — including indexed and indirect modes — widened to 64 bits, and applies uniformly to local and network-window addresses.

### Encoding Note

Instructions remain byte-granular and variable-length in the 6502 tradition: one-byte opcodes, with operands sized by addressing mode. Inherited 6502/65C02 instructions retain their classic opcode bytes; new I/O and concurrency operations occupy columns NMOS never defined. Near-page modes keep the hot path (queue ops, continuation ops) at 2–3 bytes per instruction. Code density is a stated goal: instruction fetch is a bandwidth consumer like any other, and a message-passing machine should not spend its bandwidth describing itself.

---

## 8. Prior Art and Positioning

The 6564-Net is deliberately positioned within a lineage, inheriting proven ideas and their hard-won lessons:

- **INMOS Transputer / occam** — the closest ancestor. `LSTN` is occam's channel input; the continuation queue is the Transputer's hardware process list. The Transputer's lesson: the programming model must be first-class, not bolted on. Here, the actor model is the ISA.
- **Erlang/OTP** — the supervision model of §5.4 in software form: cheap processes, links, exit signals, one-for-one restarts, and "let it crash" as a design discipline. The 6564-Net moves the link and the restart into gates; the philosophy transfers intact, and Armstrong's ring challenge is the architecture's benchmark of record (§2.2).
- **XMOS xCORE** — living proof that banked hardware threads with event-driven I/O deliver hard real-time without interrupts.
- **Cray T3E E-registers** — remote memory accessed through register-mapped windows; direct ancestor of the network window.
- **MIT J-Machine** — message-driven processors with hardware dispatch on message arrival.
- **SpiNNaker** — a million-core machine built on small cores and unreliable multicast messaging; validation that "unreliable, honest, and fast" scales.
- **io_uring / NVMe queue pairs** — the SQ/CQ discipline, proven at OS and device level, here moved into the core.
- **RDMA (rkeys)** — the capability-token model for network-exposed memory.

The synthesis is the novelty: no prior architecture combines 6502-grade architectural minimalism, IPv6-native global addressing, hardware queue-pair semantics, and silicon-level supervision in a single ISA whose unit of execution is the actor.

---

## 9. Reference Simulator: Status and Results

sim6564 (Zig; comptime-generated opcode dispatch from a declarative ISA table that also drives the assembler and documentation) implements all three phases. Full engineering detail lives in the companion implementation record; this section states what is done and what was measured.

### Phase 1 — Deterministic Core: **complete**

Cycle-stepped virtual clock, fully deterministic from a seed; banked contexts with near-page descriptor tables; the continuation queue and cooperative scheduler; single-core queue pairs.

### Phase 2 — Virtual Network Mesh: **complete**

Multi-core with PTT routing; seeded latency, jitter, loss, reordering, and duplication on off-chip paths — acknowledgments included, so the two-generals problem is live in every run. Deterministic replay is verified by test: any observed failure reproduces bit-identically from its seed.

### Phase 3 — Actor Workloads: **complete**

The three representative workloads all run, built entirely from CQ feedback and the primitives of §5–§7 — no ISA additions were needed beyond §5.4's supervision pair:

- **Ping-pong** with full end-to-end reliability over lossy fabric — retransmission timers via §6.3, sequence checking, duplicate handling.
- **A one-for-one supervision tree** — exit links, `SPWN` restarts with per-child budgets, and watchdog-caught compute hangs (the full arc: hang, trip, restart, budget exhaustion).
- **Pipeline dataflow** across N cores — per-hop stop-and-wait with ack-on-ownership overlap, backpressure by silence, and a lame-duck shutdown phase; every item checksum-verified through 73% loss.
- **Scatter-gather** (bonus workload) — idempotent workers, straggler re-scatter, no acknowledgment protocol at all: the result is the ack.

### Measured Claims

- **66 cycles per message pass** on Armstrong's ring (§2.2), flat across two orders of magnitude of scale, regression-guarded.
- 200 complete actors (register bank + near page) on one core, with room to spare.
- Zero-cycle context switch exercised on every park and yield in every test.

### Findings Promoted to Normative Spec

Implementation surfaced four results now embedded above: the fabric-as-clock timer idiom (§6.3), the copies-not-messages rule (§6.1), the delivery-consumes-the-buffer rule and slot-reuse warning (§6.2), and the watchdog burst budget (§5.4). Two design aphorisms earned by the demos are worth recording where future implementers will find them: **termination over an unreliable fabric is a phase, not an instruction** — a finished actor with an upstream must go lame-duck (parked, serving re-acknowledgments) rather than halt, or lost acks leave peers retransmitting at a corpse; and **choosing what to make reliable is the protocol design** — idempotence plus a retry timer often beats an acknowledgment protocol outright.

---

## 10. Open Questions

Recorded honestly, for future revisions. Two of v2's questions are resolved; their answers are now normative.

**Resolved.**

- ~~*(v2 Q3)* Multi-core coherence stance~~ — **Resolved: no coherent shared mutable memory between contexts; message passing only.** The near page is hardware-private (§3.1). Code pages are shared read-only: the demos run many actors from one program image at one address, with per-actor configuration delivered via the `SPWN` argument. (The v0.1 simulator enforces near-page privacy and trusts software for RAM above it; silicon should enforce both.)
- ~~*(v2 Q7)* Residual need for classical interrupts~~ — **Resolved: none.** Threshold events into the continuation queue handle all I/O occasions, and the §5.4 watchdog converts the one case events cannot reach — the compute-hung context — into an ordinary fault. The architecture has no interrupt controller.

**Open.**

1. **PTT size and miss handling** — fixed small table with software reload (TLB-style trap), or hardware-walked prefix structure?
2. **Inbound flow control** — position taken and validated: a flooded receive ring drops and reject-completes (honest), and end-to-end backpressure emerges from *silence* — a receiver that cannot take ownership simply doesn't acknowledge, and the sender's §6.3 timer becomes its retry-with-delay loop. Whether watermark-based backpressure *hints* would be worth their silicon remains open.
3. **Privilege model** — how minimal can the privileged layer be if PTT entries, exit links, and watchdog budgets are the only privileged state? A two-level model (capability kernel / actors) still looks sufficient.
4. **Timer parameters (§6.3)** — is `send_timeout` per-send, per-PTT-entry, or global? Should an architecturally reserved black-hole PTT slot exist so timer code is portable?
5. **SQ drain-rate modeling** — v0.1's RBC drains submission queues instantly, so "`SEND` parks on full SQ" is defined but unexercised. A drain-rate model is needed before the full-SQ path can be trusted.
6. **CQ overflow** — v0.1 drops and counts overflowed completions. Dropping a completion record weakens the "CQ always receives a record" guarantee under pathological sizing; an io_uring-style overflow side-channel may be warranted, or the guarantee should be restated as conditional on adequate CQ capacity.

---

*The 6502 proved that a small, honest machine could carry a revolution. The 6564-Net is a wager that the same virtues — tiny state, predictable behavior, semantics that never lie — are exactly what a planet-scale mesh of communicating actors has been waiting for. The wager now has its first receipts: sixty-six cycles, two hundred actors to a core, and every lesson the fabric taught folded back into the page you are reading.*
