# The 6564-Net Architecture

**A 64-bit silicon actor machine: minimalist microarchitecture with native network addressing, hardware queue pairs, and free-running concurrency.**

*Draft v2.4 — Entrained AI Research Institute — July 2026*

> **Changes from v2.3.** New **§6.5 — Leaving the Die: the IO Plane**.
> Multi-die machines become architectural: the PTT entry's routing hint is
> formalized as a **route selector byte** (route 0 = the on-die mesh;
> non-zero routes name off-die paths), and delivery semantics off-die are
> §6.1 unchanged at higher latency — programs cannot tell remoteness
> except by reading the bill. The reference simulator implements the plane
> as a conservative-horizon cluster, one die per host thread, bit-identical
> at any thread count (§10); open question 8 is resolved by construction
> and by measurement. Null cost holds again: the frozen table reproduces
> byte-identically for single-die machines.

> **Changes from v2.2** *(carried forward)*: §7 — Peripherals: the Fabric
> Is the Bus. Devices are actors on the **peripheral row** (`$FF00`–`$FFFE`),
> reached through PTT capabilities, gated by tokens, answering through the
> reply-window convention — no MMIO, no interrupt controller, no DMA engine
> distinct from the RBC. Sections renumbered (ISA sketch → §8, prior art
> → §9, simulator → §10, open questions → §11).

> **Changes from v2.1** *(carried forward)*: the MAC & chains campaign
> concluded; its measured survivors became normative — the 32-byte
> submission-entry format with hardware cookie stamping and the completion
> source-ring field (§4.2), and **autonomous descriptor behavior**: `LINK`
> chains with the `chain_cancelled` guarantee and `AUTO_REARM` timers
> (§4.3). §6.3 gained the stage-once timer idiom. Not adopted: `MAC`
> (deferred with its data) and `AUTO_REPOST` (permitted as an optional
> implementation feature). `ECHO` was never built, as designed.

> **Changes from v2** *(carried forward)*: §5.4 Supervision and the Watchdog;
> §6.3 Timers: the Fabric as Clock; the copies-not-messages rule in §6.1; the
> slot-reuse warning in §6.2; the `SPWN` instruction; measured numbers in
> §2.2 and §10; open questions 3 and 7 resolved; Erlang/OTP in the prior art.

---

## 1. Executive Summary

The 6564-Net is a 64-bit microprocessor architecture that treats the network as memory and the actor as the fundamental unit of execution. It descends philosophically from the MOS 6502 — small architectural state, predictable timing, honest semantics — and scales that philosophy to a world of distributed, message-passing computation.

Modern architectures pay enormous taxes that are invisible only because they are universal: OS context switches measured in microseconds, network stacks that traverse a dozen software layers per packet, and synchronous I/O models that stall cores waiting on events the silicon could have handled itself. The 6564-Net eliminates these layers by baking three things directly into the instruction set:

1. **Network addressing as memory addressing.** Remote destinations are reached through ordinary 64-bit pointers via a hardware translation window onto IPv6 space.
2. **Queue pairs in silicon.** All I/O flows through hardware-managed submission and completion rings — the io_uring / NVMe model, implemented in gates rather than kernel code.
3. **Free concurrency.** The architectural state is five 64-bit registers. Full hardware contexts cost 41 bytes each, making banked, zero-cycle context switching not an aspiration but an arithmetic fact.

The result is a **silicon actor machine**: each hardware context is an actor with a mailbox (its receive ring), an address (its IPv6-mapped window), asynchronous message semantics, and — as of this revision — hardware-enforced supervision and fault isolation. The 6564-Net is the native substrate for actor-model operating systems: it executes in hardware what systems like MiOS implement in software, and what Erlang/OTP proved in production.

These claims are no longer only claims. The reference simulator implements every phase of §10, and the measured cost of a full receive-to-forward message pass between hardware actors is **66 cycles** (§2.2).

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

The near page is architecturally **private to its context** — the one region of memory whose isolation the hardware enforces unconditionally (see §11, resolved question 3).

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
- A **route selector** (§6.5): route 0 is the on-die mesh; non-zero
  routes name off-die paths — another die, an off-chip NIC. One byte is
  the entire architectural footprint of remoteness.

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

### 4.2 Submission Entries and Completion Records

**The submission entry (SQE)** is a normative 32-byte format — the same granularity as a descriptor slot, staged by software wherever it likes (SQ ring storage, or the near page for chain entries):

```
offset  field       width  meaning
0       op          8      send / txr (register-immediate) / reserved
1       flags       8      bit 0 LINK, bit 1 AUTO_REARM (§4.3), bit 7 OWNED (§6.2)
2       link        16     near-page offset of the next chained entry (0 = none)
4       reserved    32
8       target      64     window pointer (PTT-mapped)
16      buf/value   64     buffer base (send) or the 8-byte immediate (txr)
24      len         32     bytes
28      cookie_lo   32     software's half of the completion cookie
```

**Completion records.** Every asynchronous operation eventually posts exactly one to the relevant CQ:

```
┌────────────┬──────────┬─────────────┬────────────┬──────────────────────┐
│ op tag     │ status   │ source ring │ byte count │ cookie (64-bit)      │
└────────────┴──────────┴─────────────┴────────────┴──────────────────────┘
```

The **source-ring field** names the descriptor slot the record pertains to — the RX ring for deliveries, the SQ for submissions (0 for ring-less register sends). The cookie's low half is software's `cookie_lo`; hardware stamps the high half with the entry's **staging location and the context's incarnation**, so completion records are self-identifying and a `SPWN`-restarted actor cannot misattribute a dead life's completions.

Status codes distinguish success, truncation, remote reject (capability failure), no-buffer reject, timeout, and chain cancellation (§4.3). **There is no other channel for I/O status.** No sticky error flags, no exceptions from network conditions — the CQ is the single source of truth, and software consumes it at its leisure.

### 4.3 Autonomous Descriptor Behavior

The RBC may act on software's behalf, under one discipline: **it acts only through staged entries software wrote, re-read at action time, and nothing it does is silent** — every autonomous submission posts its completion record through the same CQ as a hand-issued one. The re-read is load-bearing: the staged entry's *current bytes* are the contract, which is what makes clearing a flag bit a race-free disarm.

**`LINK` — success-chained submission.** When an entry with the LINK flag completes **ok**, the RBC submits the staged entry at its `link` offset. Chains are linear; the walk continues entry by entry, each firing on the previous one's ok. On any non-ok completion, the chain breaks *loudly*: every remaining staged entry posts a **`chain_cancelled`** completion record, cookie intact, count zero. The mandatory-completion guarantee thus extends to chains — software that stages N entries collects N records, always. Fire-on-success-only is deliberate (the io_uring rule): no conditional chains, no failure-path chains — that road leads to a hidden programming language in the queue machinery.

**`AUTO_REARM` — self-sustaining timers.** When an entry with the AUTO_REARM flag completes with **timeout**, the RBC re-reads and resubmits it. Combined with §6.3, this makes the architectural timer stage-once: arm with one doorbell, tick forever, disarm with one store that clears the flag (at most one already-in-flight tick follows — a bounded, benign race). The mechanism keys on completion status alone; aimed at a routable target it becomes retransmit-until-acknowledged, permitted but subject to §6.1's copies-not-messages caveat. AUTO_REARM takes precedence over LINK on the same entry: a rearming entry's chain awaits its next attempt rather than cancelling.

**The transistor budget, stated honestly.** Both mechanisms reuse the SEND-accept datapath and the descriptor-fetch path the RBC already has; the incremental silicon is a status comparator and a second address source. Everything that *scales* — chain topology, payloads, timer parameters, how many chains exist — lives in software-visible memory. Memory is transistors too, but shoved somewhere better: inspectable, per-actor, capability-guarded, and free when unused. That is the trade this architecture makes everywhere, made once more.

**Not adopted, recorded for honesty.** `AUTO_REPOST` (hardware re-enqueue of consumed landing buffers at CQPOP time) measured flat on cycles; it is *permitted* as an implementation feature — its real value is making the missed-repost bug class unrepresentable — but no software may require it. `MAC` one-byte vectored calls remain a sketch with data attached. Delivery-triggered ack templating (`ECHO`) was rejected outright: an ack only hardware saw is exactly the ack the end-to-end argument says nobody should trust. The full measurement ledger lives in the implementation record.

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

With §4.3's `AUTO_REARM`, the idiom is stage-once: an auto-rearming entry aimed at a black hole ticks forever. Arming is one doorbell; disarming is one store; every tick remains visible in the CQ, because a clock you cannot observe is not an honest clock.

Open details (§11): whether `send_timeout` is per-send, per-PTT-entry, or global; and whether a standardized black-hole PTT slot should be architecturally reserved.

### 6.4 Capabilities

Any memory reachable from a network is memory that must defend itself. The 6564-Net adopts the RDMA answer, enforced in hardware:

- Every PTT entry and every ring descriptor exposed to remote access carries a **64-bit capability token**.
- Inbound operations must present a matching token; the RBC checks it before any byte moves. Failures post a reject completion to *both* ends and move no data.
- Tokens are minted and revoked by privileged software. Revocation is immediate: clear the descriptor field.

This composes naturally with capability-based operating systems — a PTT entry *is* a capability in the object-capability sense, and the OS's capability graph maps directly onto silicon-enforced reachability.

### 6.5 Leaving the Die: the IO Plane

A machine is one or more **dies**; a die is one or more cores sharing an on-die mesh. Between dies runs the **IO plane** — a higher-latency transport that is *invisible to the ISA*, because the ISA never promised anything the plane cannot keep: delivery was already unreliable, latency already unspecified, ordering already per-flow-best-effort (§6.1). Off-die delivery is §6.1 unchanged, at a dearer price.

Software addresses remoteness with the PTT entry's **route selector** (§3.2). Route 0 is the on-die mesh. A non-zero route egresses the datagram to whatever the route names — another die on this board, an off-chip link — with the entry's destination coordinates interpreted *at the far end*. Everything else is untouched: `OWNED` sets on submission, the timeout arms locally, the ack (having survived the crossing twice) is an ordinary completion, and a route that leads nowhere is one more black hole for §6.3 to exploit. **A remote prefix is a prefix that is farther away.** A program wired for one die runs across sixteen when the loader flips one byte in one PTT entry — this is not a porting exercise, it is a routing table.

Two consequences are normative:

- **Plane latency strictly exceeds on-die mesh latency.** This is physics dressed as a rule, and it is load-bearing for implementations: any simulator or verification harness may advance each die independently within a horizon equal to the plane's minimum latency, exchanging traffic only at horizon boundaries, and no die will ever observe an event from its past. Determinism per seed survives multi-die; parallel hosts are an implementation detail. (The reference simulator does exactly this — §10.)
- **Timers, acks, and capabilities do not special-case the plane.** A cross-die send that dies en route is reported by the sender's local timeout, a token mismatch on a remote die rejects like any other, and driver-grade protocols (idempotent request/retry, §6.3 timers) work unmodified because they never assumed proximity in the first place.

The peripheral row (§7) rides along: an off-die bridge endpoint is addressable like any device, and a NIC is just the route selector's off-board case.

Note the limit of hardware's protection: tokens and rights guard *reachability*, not *layout*. Overlapping ring storage in RAM is a software contract violation the silicon cannot detect; memory maps remain the sharp edge they have always been.

---

## 7. Peripherals: the Fabric Is the Bus

The 6564-Net has no I/O instructions, because `SEND` *is* the I/O instruction (§8). A peripheral is not a port, an MMIO range, or an interrupt source: it is an endpoint on the fabric, with a mesh coordinate, reached through a PTT capability exactly as an actor is and gated by a capability token exactly as a ring is. **Devices are actors that happen to be made of different silicon.** This is the fabric-as-clock principle (§6.3) generalized: first the fabric was the timer; here the fabric is the bus.

### 7.1 The Peripheral Row

Coordinate rows `$FF00`–`$FFFE` of mesh space are the **peripheral row**. (`$FFFF` remains unroutable by definition: the black hole of §6.3 can never be shadowed by a device.) Coordinate bits below the row select device sub-functions and are device-defined; the v1 devices ignore them.

A send to a peripheral coordinate routes, delivers, acks, and times out under exactly the §6.1 semantics. A device hangs off the mesh, not off the core: its requests and its replies cross the same fault-injected links as any message, and nothing about delivery is special-cased. A device that cannot service a request reject-completes with `no_buffer` — ordinary flow control, retry is sane; a token mismatch reject-completes with `capability`, as always.

### 7.2 No MMIO, No Interrupts, No DMA Engine

Three classical mechanisms are deliberately absent, each displaced by something the architecture already has:

- **No MMIO.** Device registers would be shared mutable memory, and the architecture has none (§11, resolved question 3). Device state is device-private; you message it.
- **No interrupts.** Resolved question 7 removed the interrupt controller for software's sake; devices get no exemption. A device's answer is a delivery in your RX ring; the record of it is a completion in your CQ; `LSTN` parks you until it lands. **The interrupt is a message.**
- **No DMA engine.** The RBC already streams every send's buffer. A device transfer *is* a send; there is nothing left for a dedicated engine to do.

The transistor-budget argument of §4.3 applies unchanged: a device endpoint costs a row match and a small PTT, and everything that scales — sector data, console text — lives on the device side of the fabric, not in the core.

### 7.3 Replies Follow the Actor Convention

A device that answers — a clock, an entropy well, a block store — answers the way an actor answers: the request payload carries a **reply window address interpreted in the device's own PTT space**, and the loader binds the device's reply capability at attach time. Wiring a driver to its device is the same act as wiring two actors together, and revoking the PTT entry unplugs it.

Device replies are **fire-and-forget silicon**: a device does not retry, hold pending state, or wait for acknowledgment. A lost reply costs the requester another ask — so device protocols are idempotent request/retry, the same discipline every actor already lives by (§10). A reply may also race its own request-ack home across the fabric; drivers that wait on the ack must be prepared to see the answer first.

### 7.4 The v1 Device Set

Defined for the reference simulator; the set is open, the conventions above are not.

| Device | Row coordinate (convention) | Contract |
|---|---|---|
| `console` | `$FF00` | Payload bytes are text, appended to the world. No reply: the delivery ack is the receipt, and `SEND` is `PRINT`. |
| `entropy` | `$FF01` | Request {reply window, count}; replies with `count` seeded-deterministic random bytes. Same seed, same universe — still. |
| `rtc` | `$FF02` | Request {reply window}; replies with the fabric cycle at which the request arrived. §6.3 gives software intervals; the RTC gives it timestamps. |
| `block` | `$FF03` | Request {op \| sector, reply window, data…}. A write applies at delivery — the fabric ack **is** the write ack. A read sends the sector to the reply window. Both idempotent by construction. |

An off-die network bridge is the row's natural fifth citizen: a NIC is just another device. As of v2.4 the plane beneath it is architectural (§6.5) — multi-die topologies arrived as an extension, not a redesign.

---

## 8. Instruction Set Sketch (I/O and Concurrency Subset)

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

## 9. Prior Art and Positioning

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

## 10. Reference Simulator: Status and Results

sim6564 (Zig; comptime-generated opcode dispatch from a declarative ISA table that also drives the assembler and documentation) implements all three phases. Full engineering detail lives in the companion implementation record; this section states what is done and what was measured.

### Phase 1 — Deterministic Core: **complete**

Cycle-stepped virtual clock, fully deterministic from a seed; banked contexts with near-page descriptor tables; the continuation queue and cooperative scheduler; single-core queue pairs.

### Phase 2 — Virtual Network Mesh: **complete**

Multi-core with PTT routing; seeded latency, jitter, loss, reordering, and duplication on off-chip paths — acknowledgments included, so the two-generals problem is live in every run. Deterministic replay is verified by test: any observed failure reproduces bit-identically from its seed.

### Phase 3 — Actor Workloads: **complete**

The three representative workloads all run, built entirely from CQ feedback and the primitives of §5–§8 — no ISA additions were needed beyond §5.4's supervision pair:

- **Ping-pong** with full end-to-end reliability over lossy fabric — retransmission timers via §6.3, sequence checking, duplicate handling.
- **A one-for-one supervision tree** — exit links, `SPWN` restarts with per-child budgets, and watchdog-caught compute hangs (the full arc: hang, trip, restart, budget exhaustion).
- **Pipeline dataflow** across N cores — per-hop stop-and-wait with ack-on-ownership overlap, backpressure by silence, and a lame-duck shutdown phase; every item checksum-verified through 73% loss.
- **Scatter-gather** (bonus workload) — idempotent workers, straggler re-scatter, no acknowledgment protocol at all: the result is the ack.

### Measured Claims

- **66 cycles per message pass** on Armstrong's ring (§2.2), flat across two orders of magnitude of scale, regression-guarded.
- 200 complete actors (register bank + near page) on one core, with room to spare.
- Zero-cycle context switch exercised on every park and yield in every test.

### The Mechanism Campaign (v2.2)

Five pattern-collapse mechanisms were prototyped against frozen baseline measurements with pre-registered adopt/cut thresholds. Three of five predictions were wrong — split between both authors — and the data decided: `LINK` removed 24% of executed instructions where a fan-out exists (scatter's six tasks fire from one doorbell, and a mid-chain loss cancels loudly into the straggler path); `AUTO_REARM` erased every timer-rearm handler in the corpus; `AUTO_REPOST` and `MAC` measured flat and were parked and deferred respectively. The measurement record retires with the sketch, data attached.

### The Peripheral Row (v2.3)

§7 is implemented and exercised: the v1 device set (console, entropy, RTC, block) attaches at peripheral-row coordinates, and two workloads drive it end to end from assembly. `hello` is the minimal proof — one actor, one capability, one teletype. `periph` walks the whole row: the actor timestamps itself off the RTC, draws eight random bytes and prints them in hex, round-trips draw-plus-timestamp through a disk sector with verification, and prints its own cycle bill — every step a `SEND` through a capability, every answer a delivery in the same RX ring any actor would use. **Zero new opcodes were required**, which is §7's claim in one sentence. Null cost is verified: with no devices attached, the frozen v2.2 measurement table reproduces byte-identically. One driver lesson is recorded in §7.3: a reply can race its own request-ack home, so ack-waits must stash deliveries they pop.

### The IO Plane (v2.4)

§6.5 is implemented as `src/cluster.zig`: N complete machines — each running the untouched single-threaded deterministic loop — advance in conservative windows equal to the plane's base latency and exchange traffic at barriers, one host thread per die when asked. Measured, all guarded by tests:

- **Transparency**: Armstrong's ring spans 16 dies running the *unmodified* `ring_node.asm` — 3,200 actors, 320,000 passes, 77 cycles per pass including 1,600 plane crossings (`sim6564 dies`). The entire multi-die port of the workload is one route byte in the last node's PTT entry per die.
- **Determinism**: threaded and sequential runs are bit-identical — same cycle counts, same stop reasons, same plane traffic, at any thread count.
- **Host parallelism**: with every die busy, 16 host threads run the cluster 3.7× faster than one; the single-token ring, by contrast, parallelizes not at all (one die busy at a time) — Amdahl's law is about the workload, and the harness reports it honestly. Window width equals plane latency, so a dearer plane parallelizes better: the physics and the engineering point the same way.
- **Null cost**: single-die machines reproduce the frozen measurement table byte-identically; `run()` is now literally `runUntil(∞)`.
- **Across host processes** (`sim6564 net`): die ids federate (each process owns a `node_base` range), and the window barriers cross a real TCP socket as frames of virtual-time-stamped datagrams. The wall clock never enters the virtual machine, so the whole federation replays bit-identically from its seeds regardless of real network timing — the ring spans two OS processes on the same unmodified program bytes, and the token comes home. TCP is just a slow backplane.
- One implementation lesson worth silicon designers' attention: cross-die send-ids are per-die counters, so a delivery must carry its origin die and an ack must never consult the local pending map for a foreign datagram — the first draft leaked exactly that, and the plane's own traffic counters caught it (1,510 acks for 40 datagrams).

### Findings Promoted to Normative Spec

Implementation surfaced four results now embedded above: the fabric-as-clock timer idiom (§6.3), the copies-not-messages rule (§6.1), the delivery-consumes-the-buffer rule and slot-reuse warning (§6.2), and the watchdog burst budget (§5.4). Two design aphorisms earned by the demos are worth recording where future implementers will find them: **termination over an unreliable fabric is a phase, not an instruction** — a finished actor with an upstream must go lame-duck (parked, serving re-acknowledgments) rather than halt, or lost acks leave peers retransmitting at a corpse; and **choosing what to make reliable is the protocol design** — idempotence plus a retry timer often beats an acknowledgment protocol outright.

---

## 11. Open Questions

Recorded honestly, for future revisions. Two of v2's questions are resolved; their answers are now normative.

**Resolved.**

- ~~*(v2 Q3)* Multi-core coherence stance~~ — **Resolved: no coherent shared mutable memory between contexts; message passing only.** The near page is hardware-private (§3.1). Code pages are shared read-only: the demos run many actors from one program image at one address, with per-actor configuration delivered via the `SPWN` argument. (The v0.1 simulator enforces near-page privacy and trusts software for RAM above it; silicon should enforce both.)
- ~~*(v2 Q7)* Residual need for classical interrupts~~ — **Resolved: none.** Threshold events into the continuation queue handle all I/O occasions, and the §5.4 watchdog converts the one case events cannot reach — the compute-hung context — into an ordinary fault. The architecture has no interrupt controller.

**Open.**

1. **PTT size and miss handling** — fixed small table with software reload (TLB-style trap), or hardware-walked prefix structure?
2. **Inbound flow control** — position taken and validated: a flooded receive ring drops and reject-completes (honest), and end-to-end backpressure emerges from *silence* — a receiver that cannot take ownership simply doesn't acknowledge, and the sender's §6.3 timer becomes its retry-with-delay loop. Whether watermark-based backpressure *hints* would be worth their silicon remains open.
3. **Privilege model** — how minimal can the privileged layer be if PTT entries, exit links, and watchdog budgets are the only privileged state? A two-level model (capability kernel / actors) still looks sufficient.
4. **Timer parameters (§6.3)** — is `send_timeout` per-send, per-PTT-entry, or global? Should an architecturally reserved black-hole PTT slot exist so timer code is portable?
5. **SQ drain-rate modeling** — v0.1's RBC drains submission queues instantly, so "`SEND` parks on full SQ" is defined but unexercised. Chain fires (§4.3) give the RBC its first architecturally visible non-instant work, and are the natural seam for a drain-rate model.
6. **CQ overflow** — v0.1 drops and counts overflowed completions. Dropping a completion record weakens the "CQ always receives a record" guarantee under pathological sizing; an io_uring-style overflow side-channel may be warranted, or the guarantee should be restated as conditional on adequate CQ capacity.
7. **Peripheral discovery** — v2.3 binds device capabilities statically at load time, like everything else the loader wires. Whether enumeration ("what lives on this row?") is an architectural protocol or purely a software convention is undefined.
8. ~~**Off-die bridges and multi-die time**~~ — **Resolved in v2.4 (§6.5): the route selector and the IO plane.** The conservative synchronization contract (window = plane minimum latency) is normative-by-consequence and validated: the reference simulator runs one die per host thread, bit-identical to sequential at any thread count. Remaining sub-question: route selectors are per-PTT-entry and loader-assigned; whether route discovery/topology description deserves architectural surface belongs with question 7's discovery story.

---

*The 6502 proved that a small, honest machine could carry a revolution. The 6564-Net is a wager that the same virtues — tiny state, predictable behavior, semantics that never lie — are exactly what a planet-scale mesh of communicating actors has been waiting for. The wager now has its first receipts: sixty-six cycles, two hundred actors to a core, every lesson the fabric taught folded back into the page you are reading — and, as of this revision, `HELLO, WORLD` in the machine's own voice.*
