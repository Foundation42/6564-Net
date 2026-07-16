# Sixty Cycles Around the Ring

## The 6564-Net: A Silicon Actor Machine Descended from the 6502

**Christian Beaumont**
Entrained AI Research Institute, West Yorkshire
*Draft — July 2026*

---

### Abstract

We present the 6564-Net, a 64-bit microprocessor architecture whose unit of execution is the actor and whose memory model extends, through a hardware translation window, onto native IPv6 address space. The design descends deliberately from the MOS 6502: five registers, a private 4 KB "near page" in the zero-page tradition, byte-granular encoding, and cycle-countable execution. From this minimalism three properties follow by arithmetic rather than aspiration: a complete execution context costs 41 bytes, context switches are single-cycle bank selections, and two hundred concurrent actors fit on one core with room to spare. All I/O flows through hardware submission/completion queue pairs with a single normative guarantee — every operation posts exactly one truthful completion record — from which retransmission timers, backpressure, supervision, and even the machine's only clock are derived rather than added. We describe the architecture; its reference implementation, a deterministic discrete-event simulator whose multi-die and multi-process federations replay bit-identically at any thread count; and a measurement-first design method in which every proposed mechanism was prototyped, measured against pre-registered thresholds, and adopted, parked, or cut accordingly — with every wrong prediction retained in the ledger. Headline results under the reference cycle model: Armstrong's N-processes-in-a-ring challenge at 60 cycles per message pass; a 10,000-sender fan-in absorbed at 55 cycles per message with zero completion records lost; end-to-end reliable pipelines verified through 73% injected packet loss; and an HTTP/1.1 client, written in 6502-descendant assembly, that fetched a real web page from the live internet in 784 instructions.

---

## 1. Introduction

Modern computing pays taxes so universal they have become invisible. An operating-system context switch costs microseconds of saved and restored state. A network datagram traverses a dozen software layers before an application sees it. A core that issues synchronous I/O stalls, and the machinery that hides the stall — interrupts, schedulers, completion callbacks stacked on epoll stacked on device queues — constitutes much of the complexity budget of a contemporary system. Meanwhile the workloads themselves have changed shape: the interesting programs of this decade are meshes of small communicating agents — services, actors, model instances — for which the expensive abstractions (coherent shared memory, synchronous calls, reliable in-order byte streams) are precisely the ones they spend their engineering effort escaping.

The 6564-Net begins from a different question: what would a processor look like if the actor — private state, an inbox, an address, asynchronous sends, supervised failure — were the architectural primitive, and everything else were derived? Our answer is deliberately conservative in one dimension and radical in another. Conservative: the machine is a direct philosophical descendant of the MOS 6502, an architecture whose virtues — tiny state, honest semantics, countable cycles — were never really about the 1970s. Radical: the network is not a peripheral. Remote destinations are ordinary 64-bit pointers, resolved through a hardware window onto IPv6 space, and the machine's delivery semantics tell the truth about what networks actually do.

This paper is an overview and a progress report, not a specification (the specification, at v2.5, and the full implementation record are available in the project repository). We make three claims and support each with measurements:

1. **Architectural minimalism is a concurrency mechanism.** A 41-byte context makes hardware scheduling, supervision, and massive actor counts consequences of arithmetic (§2, §5).
2. **One honest guarantee generates the rest of the system.** Mandatory truthful completion records yield timers, flow control, fault tolerance, and device I/O without dedicated silicon for any of them (§3, §4).
3. **Measurement-first architecture evolution works**, including — especially — when the measurements contradict the architects (§6).

## 2. The Machine in One Section

**Contexts.** The architectural state of a thread of execution is five 64-bit registers (A, X, Y, SP, IP) and an 8-bit status register: 41 bytes. Contexts are banked in hardware; a switch is a mux selection, not a memory transfer. A 16 KB register file holds roughly four hundred complete contexts. Scheduling is cooperative and event-driven: a context runs until it parks waiting on a queue, yields, halts, or faults, whereupon the core proceeds to the next runnable continuation in the same cycle. There is no busy-waiting anywhere in the model; the concept does not exist.

**The near page.** The bottom 4 KB of each context's address space is private, hardware-enforced, and held adjacent to the register banks — the 64-bit descendant of the 6502's zero page. It is where the architecture keeps its nouns: ring descriptors, staged submission entries, continuation slots. Because descriptors live at architected near-page offsets, the I/O instructions take one-byte operands, and code density stays in the 6502's league on a 64-bit machine.

**The network window.** All pointers are 64 bits. Addresses whose top byte selects the window are resolved through the Prefix Translation Table (PTT), a small TLB-like structure mapping window slots to 128-bit IPv6 prefixes, access rights, routing hints, and a capability token. A store to a local buffer, a neighboring core, another die, or another continent is the same instruction with a different pointer; the IPv6 framing materializes only when a datagram actually leaves the machine. Loading the PTT is privileged: software decides what the world looks like, silicon enforces it.

**Queue pairs.** All asynchronous I/O flows through hardware-managed submission and completion rings — the io_uring/NVMe discipline moved into the core. Autonomous ring controllers handle pointer arithmetic, watermark events, and (since v2.2) two forms of descriptor autonomy adopted after measurement: *linked chains*, in which the successful completion of one staged operation submits the next, and *auto-rearm*, in which a timed-out operation restages itself. Chains that break do so loudly: every unstarted entry receives an explicit cancellation record.

**Supervision in silicon.** Each context may carry an exit link — a supervisor and a completion-queue slot — and death is a message: on halt or fault, hardware posts an obituary record through the same machinery as every other completion. A `SPWN` instruction resurrects a context with fresh registers and a bumped incarnation counter; stale continuations from the previous life are skipped at dispatch, so a restarted actor cannot be haunted by its predecessor's pending work. A per-context watchdog burst budget — one comparator — converts the failure supervision cannot otherwise see, the compute-hung actor, into an ordinary supervisable fault. This is Erlang/OTP's one-for-one supervision tree, in gates.

**Peripherals are actors.** Devices — console, RTC, entropy, block storage, a raw network pipe — occupy mesh coordinates and are reached by ordinary sends through PTT capabilities. There is no MMIO, no interrupt controller, no DMA engine as a distinct concept, and the peripheral row added zero opcodes to the ISA. The governing rule (spec §7.5) is that **silicon is an optimization, never an interface**: every device contract must be implementable by an ordinary actor, so an HTTP engine, say, can ship as gates or as a software polyfill and no client can tell the difference.

## 3. Honest Semantics: One Guarantee, Many Consequences

The delivery model is unreliable datagram transport with **mandatory truthful completion reporting**: a send may be lost, reordered, or duplicated, but the local completion queue always — always — receives exactly one record per operation: acknowledged, rejected, or timed out. Completion records describe the fate of *copies*, not messages; end-to-end identity belongs to software. From this single guarantee, the rest of the system is derived:

**Timers.** The ISA defines no timer peripheral. A send addressed through an unroutable PTT entry vanishes into the fabric, and its timeout record arrives exactly `send_timeout` cycles later: the fabric's honesty about its own failures *is* the clock. Retransmission timers, retry-with-delay loops, and shutdown watch-timers all reduce to this idiom at zero silicon cost. This was not designed; it was discovered, when the first end-to-end protocol met the case "request acknowledged, reply lost" and needed something — anything — that would eventually wake it.

**Flow control.** A receiver that cannot take ownership of a message simply does not acknowledge it; the sender's timer becomes its retry-with-delay loop. Backpressure is the *absence* of a signal. The pipeline workload runs stop-and-wait per hop with acknowledgment-on-ownership (stages ack the moment they accept an item, not when it reaches the sink, so hops overlap), and this discipline — ack when you have room, stay silent when you don't — required no credit protocol and no window negotiation.

**Fault tolerance.** Supervision (§2) consumes the same records. So does distributed termination, which implementation taught us is *a phase, not an instruction*: a finished actor with an upstream must go lame-duck — parked, serving re-acknowledgments — rather than halt, or a lost ack leaves its peers retransmitting at a corpse forever.

**Buffer ownership.** The completion record is also the memory model's release fence: a buffer belongs to the DMA engine from send-accept until its record posts, one bit, one rule. The receive-side contract was hardened by a saturation failure (§6): a popped payload is now valid until the next completion pop from that ring — unconditional, and enforced by a deferred buffer grant costing one bit of hardware state.

## 4. The Reference Implementation

sim6564 is a discrete-event reference simulator in Zig. One declarative ISA table, evaluated at compile time, generates the decoder, the two-pass assembler, and the documentation of record; adding an instruction is one line, and a duplicate opcode is a compile error. The simulated fabric injects latency, jitter, loss, reordering, and duplication — acknowledgments included, so the two-generals problem is live in every test run — from a single seeded generator, and every execution replays bit-identically from its seed. The suite stands at 71 green tests over seventeen 6564 assembly programs and eleven demos.

Determinism scales further than one machine. The **IO plane** federates multiple dies — each a complete machine on its own host thread — through conservative-horizon window barriers in the Chandy–Misra–Bryant tradition: sixteen dies on sixteen pinned host threads produce output bit-identical to the sequential run, at 6.1× the sequential wall clock on a 16-core host. The same plane crosses OS process boundaries over real TCP, with virtual-time-stamped datagrams framed on the wire, so a federation spread across a physical network still replays bit-identically from its seeds: the wall clock never enters the machine, and TCP is just a slow backplane. Thread placement, cache residency, and allocator choice change seconds, never bits — a property we verify continuously, and which converts distributed-systems debugging from anecdote into replay.

The capstone workload closes the loop with the real world: `http_get.asm`, written in the 6564's 6502-descendant assembly, speaks HTTP/1.1 through the raw network pipe device and prints an actual page from the live internet on its teletype — 784 instructions, clean halt. The protocol lives entirely in machine code above the byte-pipe contract, as §7.5 demands it must be able to.

## 5. Measured Results

All cycle figures are simulated cycles under the reference cycle model — a claim about the architecture's bookkeeping, to be revalidated against any physical implementation. Determinism makes every number below exactly reproducible from its stated seed.

| Workload | Scale | Result |
|---|---|---|
| Armstrong ring (*Programming Erlang*, ch. 12) | 200 contexts × 1,000 laps | **60 cycles/message pass** at steady state, receive-to-forward, scheduling and completion handling included; flat across two orders of magnitude; regression-guarded |
| Fan-in ("Big Brother") | 10,000 senders → 1 target | **55 cycles/absorbed message**; every sender heard exactly once; zero completion records lost — saturation manifests as backpressure, not corruption |
| Fork/join | 1 → 1,000 workers → 1 | 61,000-cycle makespan across ~2,010 actors; fan-out is hierarchical *by construction* (a destination costs a PTT slot, a chain entry costs 32 near-page bytes) |
| Reliable pipeline | N stages, injected faults | Every item checksum-verified through **73% packet loss**; shutdown converges via lame-duck draining |
| Supervision tree | 1 supervisor, mixed failures | Crashes, hangs (watchdog-caught), restart-budget exhaustion — all observed as ordinary completion records |
| Live web fetch | 1 actor, real internet | HTTP/1.1 GET of example.com in **784 instructions** |

Context arithmetic, verified in every run: 41 bytes of architectural state per actor; 200 actors resident per core; a context switch on every park and yield, at zero cycles, ~13,000 times per benchmark suite execution.

## 6. Method: Measurement-First Evolution, Wrong Guesses Included

The architecture grew by a repeated cycle: propose a mechanism with pre-registered adopt/park/cut thresholds, prototype it in the simulator, measure it against the full workload corpus, and record the outcome — *including the predictions it falsified*. The pattern-collapse campaign is the worked example. Five mechanisms were sketched to absorb recurring code patterns: one-byte vectored calls (`MAC`), automatic receive-buffer reposting, self-rearming timers, completion-linked submission chains, and hardware acknowledgment templating. The pre-registered predictions went two for five.

`MAC` — predicted an easy code-density win — could touch at most 3.6% of the corpus, because straight-line protocol loops contain almost no repeated subroutine-shaped material; it is deferred until a richer corpus (an operating system, §8) exists to re-judge it. Automatic reposting — predicted the biggest single win — measured flat-to-negative, and its original validity contract *corrupted data at saturation*; the repaired contract (deferred grant, §3) is stronger and simpler, and the mechanism is retained as optional because it makes a real deadlock class unrepresentable, not because it saves instructions. Linked chains — predicted marginal — removed 24% of the scatter workload's executed instructions by making the fan-out loop run zero times on the happy path, and were adopted. Self-rearming timers performed exactly as predicted (flat on counts, a clear win in protocol simplicity: the arm is one doorbell, the disarm is one store, and a stray final tick is bounded by construction) and were adopted. Acknowledgment templating was never built, on end-to-end-argument grounds the workloads had already demonstrated: meaningful acknowledgments are application decisions.

Meanwhile the largest single improvement of the entire project came from none of the clever machinery: counted shifts — a constant-time barrel shifter behind four classic mnemonics — removed 21% of all executed instructions corpus-wide and took the ring benchmark from 66 to 60 cycles. The `MAC` analysis, in the act of failing its own bar, was what pointed at the shift-heavy idioms. We draw the general lesson explicitly: **autonomous hardware pays where it replaces executed software loops, and not where it merely relocates an instruction** — and a measurement regime is worth most when it is wrong productively.

Two host-side findings from the multi-die work generalize beyond this project. The shared general-purpose allocator, not the architecture, was the end-to-end bottleneck of the parallel simulator (switching to a thread-aware allocator improved even the *sequential* baseline 7.7×); and a cache experiment must defeat the hardware prefetcher before it measures the cache — our capacity study read nothing until its linear stride became a maximal-period LFSR walk, whereupon the V-cache advantage appeared exactly in the band where 96 MB holds what 32 MB cannot.

## 7. Related Work

The 6564-Net is a synthesis with named parents. The INMOS Transputer is the closest ancestor — our park-on-input is occam's channel input, our continuation queue its hardware process list — and its deepest lesson, that the programming model must be first-class rather than bolted on, is our organizing principle. Erlang/OTP contributes the supervision philosophy of §2 and our benchmark of record; the 6564 moves the link and the restart into gates. XMOS xCORE demonstrated banked hardware threads with event-driven I/O delivering hard real time without interrupts. The Cray T3E's E-registers prefigure the network window; the MIT J-Machine, message-driven dispatch; SpiNNaker, the viability of vast meshes of small cores over honest unreliable multicast. The queue-pair discipline is io_uring's and NVMe's, proven at OS and device level; the capability tokens guarding network-exposed memory are RDMA's rkeys; the deterministic federation is conservative parallel discrete-event simulation in the Chandy–Misra–Bryant tradition. We claim novelty for the synthesis: no prior architecture combines 6502-grade minimalism, IPv6-native addressing, hardware queue-pair semantics, and silicon-level supervision in one ISA whose execution unit is the actor — nor, to our knowledge, has an architecture derived its timers, flow control, and fault tolerance from a single completion-honesty guarantee.

## 8. Where This Goes

Three directions are open and ordered. First, **an operating system**: the machine was always the substrate for one. A capability kernel in the MiOS tradition occupies the privileged seam the architecture deliberately left small — PTT loading, exit-link wiring, watchdog budgets — with supervision trees as the native process model; it also supplies the subroutine-rich corpus on which the deferred `MAC` mechanism gets its honest re-trial. Second, **the open questions the measurements sharpened**: PTT sizing (fan-out degree is now a measured architectural constant), timer parameterization, submission-queue drain-rate modeling, and completion-queue overflow semantics. Third, **a physical target**: the cycle model is deliberately conservative, the ISA table is a single declarative artifact, and an FPGA realization is the natural referee for every simulated claim in §5.

## 9. Conclusion

The 6502 proved that a small, honest machine could carry a revolution. The 6564-Net is a wager that the same virtues — tiny state, predictable behavior, semantics that never lie — are what a planet-scale mesh of communicating actors has been waiting for; that fault tolerance, location transparency, and capability security belong in the architecture rather than atop it; and that the right abstraction in the right place makes the layers above simpler, not merely possible. The wager now has receipts: sixty cycles around Armstrong's ring, ten thousand voices heard exactly once, checksums intact through 73% loss, a web page fetched by an assembly program descended from 1975 — and a ledger in which every claim is measured, every measurement replays from its seed, and every wrong guess is kept where future readers can learn from it.

---

### Acknowledgments

The architecture, implementation, and measurement campaign were developed in sustained collaboration with Claude (Anthropic), whose contributions ran from the network-window and supervision designs to the pre-registered predictions this paper cheerfully reports were wrong. The debt to Joe Armstrong's worldview — the world is parallel, processes should be cheap, failure should be honest — will be evident on every page; we like to think he would have enjoyed the ring numbers.

### Availability

Specification (v2.5), implementation record, measurement ledger, simulator, assembler, and all seventeen assembly programs: **github.com/Foundation42/6564-Net**. Every figure in this paper regenerates deterministically from the stated seeds via `sim6564 measure`.
