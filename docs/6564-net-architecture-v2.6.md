# The 6564-Net Architecture

**A 64-bit silicon actor machine: minimalist microarchitecture with native network addressing, hardware queue pairs, and free-running concurrency.**

*Draft v2.6 — Entrained AI Research Institute — July 2026*

> **Changes from v2.5.** This revision is transcription, not design:
> every change below was implemented, measured, and adversarially
> exercised before it was written down — most of it *through* joe, the
> architecture's language, whose compiler became the measuring
> instrument the post-v2.5 plan said it would be.
>
> **The register file collapses (§2.2, §3.4).** The machine never had
> preemption — every context switch was voluntary or fatal — so the
> banked register file was storing state nobody could ever legally
> read. Registers (A, X, Y, SP, P — and V0–V7) are now **one shared
> set per core, volatile across parks**; a context is a near page, a
> run-queue entry, and a **control block** (an architected near-page
> stripe, write-protected against its own context: incarnation, exit
> link, watchdog budget, WDEX ceiling — an actor must not edit its own
> leash). `SPWN` simplifies to almost nothing. Measured through joe:
> the compiled ring fell from 110 to **55.26 cycles per pass — under
> the 60-cycle hand-written figure** — and the whole compiled corpus
> runs **cycle-identical with every register poisoned at every park**
> (the `scorch` verifier), which is the collapse's proof obligation
> discharged mechanically rather than by argument.
>
> **Contended LSTN (§5.2).** Immediate hot-path delivery is a
> privilege of an idle core: an `LSTN` that finds its ring non-empty
> still rotates when another live context on the core is runnable.
> One branch against run-queue state; replay stays bit-exact; measured
> price **zero cycles on every existing benchmark** — the collapse
> made the switch free, so fairness costs one honest branch. This
> closes the one invisible failure the supervision story had left:
> an unwatchdogged hot loop starving its neighbors silently.
>
> **`WDEX` — supervisor-ceilinged burst declarations (§5.4).** An
> actor may declare a long burst up to a privileged ceiling; above it,
> a `wdex_ceiling` fault. The budget runs on the *dispatch clock*, so
> an unparked loop is one accumulating burst and an armed watchdog
> does eventually trip it. joe's `bounded` is *checked*: the compiler
> bills every emitted instruction from this document's own cycle
> tables, rejects understatement, and leaves the watchdog judging only
> what static analysis cannot see — data.
>
> **The extended opcode page and the FP tiers (§8.1).** One prefix
> byte — `$42`, WDM, the byte the 65816 reserved and never spent —
> opens a second 256-entry page, non-stacking by hard rule. Tier 0:
> scalar IEEE-754 f64 in A, round-to-nearest-even, no FTZ, no fusion,
> bit-exact and oracle-tested (a Mandelbrot rendered character-exact
> against host arithmetic). Tier 1: **V0–V7 × 512 bits on the
> extended page's `$?7` column** — the base page spent its `$?7` on
> I/O; the extended page spends its on the vector unit — one shared
> file per core, park-volatile like everything else now.
> **Reduction order is part of the contract**: `VRADD` is the pairwise
> tree, one shape always, and the suite proves the shape by
> distinction. Measured: a 256-element dot product at **6.4×** over
> the scalar loop, both results bit-exact against their own mirrors.
>
> **Registered regions (§6.2).** Ownership widens from one transmit
> buffer to one region using mechanisms the page already had: **the
> descriptor table is the region table** (a region is a descriptor
> with the REGION flag: base, length, token), grant-on-submit sets an
> OWNED flag, **the completion record is the release fence**, and
> revocation is the owner zeroing its own token word — whereupon a
> late DMA re-reads the live descriptor and reject-completes instead
> of scribbling. The matmul accelerator ships in two implementations —
> in-proc gates and a fabric-remote polyfill that pulls the region
> through the network window with the same token (the future the PTT
> `write` right was reserved for) — driven by the *same program*,
> agreeing to the bit, per §7.5. Grant completions carry the
> architected tag `$6772`. joe enforces §6.2 at compile time: a
> granted region is unreachable *by type* until its completion case
> rebinds it.
>
> **MAC, re-tried with the reuse it was waiting for (§8.2).** The v2.2
> deferral said re-measure when compiled code exists. It does: a
> store actor writes the same byte-comparator twelve times, and MAC
> routing collapses it to **−31.4% code at +3.0% cycles** — the 3%
> being call linkage plus the per-burst stack re-establishment the
> collapse otherwise abolished. Adopted as an **optional feature**
> (AUTO_REPOST's category), opt-in per deployment; cross-actor sharing
> awaits a shared-code-pages story (§11).
>
> Also carried in from the joe campaign, language-side but
> spec-relevant: canonical struple bytes as the tuple wire format
> (thirteenth conformant implementation, proven on this machine under
> scorch), the architected grant-completion tag, the `pack_overflow`
> fault code (reserved), and a fault-code table that now ends
> `watchdog, bad_macro, wdex_ceiling, cq_overflow` — the last of those
> promoted from open question 6 in v2.6 (§4.2): a lost delivery or
> obituary kills the context that could not hold it, so the exit link
> fires; a lost transport verdict still drops and counts, because the
> peer will say it again.

> **Changes from v2.4** *(carried forward)*. New **§7.5 — Protocol Stacks: Silicon Is an
> Optimization** — the polyfill principle becomes normative: a device
> contract is valid only if an ordinary actor could implement it, so
> whether an endpoint is gates or 6564 code is a deployment decision a
> client cannot observe. §7.4 gains the **net** device (the raw byte
> pipe to real TCP) and, with it, the determinism scope: the outside
> world is the one device that does not replay — everything on our side
> of the socket still does. §10 gains the capstone: `http_get.asm`
> speaks HTTP/1.1 through the net device and fetches a real web page.
> Also: **counted shifts** — `ASL/LSR/ROL/ROR #n` in the `$?B` column
> (§8): a barrel shifter is constant-time silicon, so any count costs 2
> cycles; count mod 64, count 0 a flag-preserving no-op, carry = the
> last bit shifted out. Field-extraction idioms shrink from eight-line
> shift ladders to one instruction; the corpus retires 21% fewer
> instructions, and the ring pass drops from 66 to **60 cycles**.

> **Changes from v2.3** *(carried forward)*: **§6.5 — Leaving the Die: the IO Plane**.
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
3. **Free concurrency.** The architectural state is five 64-bit registers — one shared set per core, volatile across parks. A context is a near page, a run-queue entry, and a control block; switching is a run-queue pop, and as of v2.6 there is nothing to save at all.

The result is a **silicon actor machine**: each hardware context is an actor with a mailbox (its receive ring), an address (its IPv6-mapped window), asynchronous message semantics, and — as of this revision — hardware-enforced supervision and fault isolation. The 6564-Net is the native substrate for actor-model operating systems: it executes in hardware what systems like MiOS implement in software, and what Erlang/OTP proved in production.

These claims are no longer only claims. The reference simulator implements every phase of §10, and the measured cost of a full receive-to-forward message pass between hardware actors is **60 cycles** (§2.2).

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

**Total: 41 bytes — and as of v2.6, none of it is saved.** Earlier
revisions banked this state per context. Implementation forced the
sharper question: *who ever reads a banked register?* Every context
switch in this architecture is voluntary (`LSTN`, `YLD`, a full-SQ
`SEND`) or fatal (a fault — and faults were never resumable;
supervision restarts via `SPWN` with fresh registers). There is no
moment at which hardware must preserve register state on anyone's
behalf. So the registers are **one shared set per core, volatile
across every park**, and a context is exactly three things:

- its **near page** (the state that survives, where 6502 heritage
  always kept it — variables lived in zero page; registers were
  transient scratch),
- its **run-queue entry** (context, incarnation, resume IP),
- its **control block** — an architected near-page stripe,
  **write-protected against the owning context** (§3.4): incarnation,
  exit link, watchdog budget, WDEX ceiling. An actor must not edit
  its own leash. This stripe is the one new mechanism the collapse
  required; everything it deleted — the banked file, `SPWN`'s
  register reset — it deleted for free.

The compiler treats every potentially-parking instruction as a full
register clobber (the set is exactly `LSTN`, `YLD`, `RECV`, `SEND` —
enumerable and small), and near-page-resident state means parked
values are used *in place*, never "restored."

This is the XMOS xCORE / barrel-processor lineage taken to its
conclusion: the zero-cycle context switch is no longer a bank select —
it is *nothing at all*, a run-queue pop.

**Measured, twice over.** Armstrong's N-processes-in-a-ring challenge
(*Programming Erlang*, ch. 12): the hand-written ring passes a
single-register `TXR` in **60 cycles** receive-to-forward, flat from
64 contexts × 100 passes to 200 × 1000; the ring *compiled from joe*
passes in **55.26** — the convention beat the heroics, because the
collapse forced dispatch discipline the hand code never had. And the
claim is verified maximally hostilely: the simulator's `scorch` mode
poisons A, X, Y, SP, P and the vector file at every real park, and
the entire compiled corpus runs **cycle-identical**. Nothing ever
trusted the banked file; now there is no banked file to trust.

---

### 2.3 Every Static Check Is the Early Copy of a Dynamic One (v2.6)

A rule the implementation kept discovering, promoted here because it is now load-bearing in three places and states this machine's trust model better than any list of guarantees:

> **A compiler never extends trust. It only moves a reject earlier in time.**

Every static check in this tower has a runtime twin that would catch the same thing later, and the twin is the one that decides:

- **`bounded` is the watchdog moved to compile time.** The compiler bills each emitted instruction from the ISA tables and refuses an understated budget; the watchdog would have force-faulted the same burst at cycle N. Data-dependent claims the compiler cannot price are simply left to the twin (§5.4).
- **The dialect check is the RBC moved to compile time.** The compiler compares a payload's claim against the endpoint the system block wires; the RBC compares the same two values at accept. A hand-written program that lies is rejected by the machine, which is why the right can be said to live in the capability rather than in the language (§6.4).
- **`scorch` is the same idea run backwards** — a dynamic check proving a static convention. The compiler promises registers never cross a park; poisoning them at every park proves it, and the corpus running cycle-identical scorched is the evidence (§2.2).

The practical value is diagnostic. **When a static check has no runtime twin, that is a smell, and usually a hole.** The gap Amendment 3 shipped with — "the compiler holds the dialect line" while the RBC checked nothing — was exactly this shape, and inspection under this rule would have found it without a program having to fail first. A check that only the compiler makes is a promise the machine has not agreed to keep.

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

### 3.3 The Control Block (v2.6)

With the register file collapsed (§2.2), the state that must survive
parks and `SPWN` is exactly four words: **incarnation counter, exit
link, watchdog base budget, WDEX declaration ceiling**. These live in
an architected near-page stripe — the **control block** — readable by
the owning context, **writable only by privileged software**
(supervisors, the loader). The rationale is one sentence: an actor
must not edit its own leash. The stripe is the collapse's entire
silicon cost; the banked register file and `SPWN`'s register-reset
machinery were its refund.

### 3.4 The Vector File (Tier 1, v2.6)

**V0–V7, 512 bits each — eight f64/u64 lanes — one file per core.**
Never banked, never saved by hardware, volatile across parks by
exactly the §2.2 convention: wide state joined the rule rather than
growing an exception. Live vector state spills to the near page or
dies with the burst; a watchdog trip mid-block loses it by design
(trips are deaths, deaths restart). The `scorch` verifier poisons the
V file wholesale at every park along with the scalars.

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

**CQ capacity is a software contract, and breaking it is fatal — selectively (v2.6).** "Every operation posts a record" holds only if the queue has room; sizing it is software's job, exactly like laying out ring storage so stripes do not overlap (§6.2). What happens when software gets it wrong depends on **what the lost record was**, and the distinction is not stylistic:

- A **transport verdict** — an ack, a reject, a timeout — is *re-derivable by construction*. The peer retransmits, the timer fires again, and an entire class of correct protocols (every actor compiled from a language with no syntax for transport verdicts) never reads them at all. An overflowed verdict is **dropped and counted**, as in v0.1.
- A **delivery** or an **exit notification** exists nowhere else. A dropped delivery is a message that was accepted and then forgotten — its sender saw an ack, its receiver waits forever. A dropped obituary is a death with no mourner. Overflowing either **faults the context that owns the queue** (`cq_overflow`), so its exit link fires and a supervisor answers for it.

This is the same move §5.2 made for starvation and §5.4 for the compute-hang: the machine has no silent-forever failures left, only supervisable ones. The narrower rule was not designed at the desk — the flat version killed a 1,009-actor fork-join tree whose lieutenants routinely overflow their CQs with their own rejects, and the tree's protocol was right to ignore them.

### 4.3 Autonomous Descriptor Behavior

The RBC may act on software's behalf, under one discipline: **it acts only through staged entries software wrote, re-read at action time, and nothing it does is silent** — every autonomous submission posts its completion record through the same CQ as a hand-issued one. The re-read is load-bearing: the staged entry's *current bytes* are the contract, which is what makes clearing a flag bit a race-free disarm.

**`LINK` — success-chained submission.** When an entry with the LINK flag completes **ok**, the RBC submits the staged entry at its `link` offset. Chains are linear; the walk continues entry by entry, each firing on the previous one's ok. On any non-ok completion, the chain breaks *loudly*: every remaining staged entry posts a **`chain_cancelled`** completion record, cookie intact, count zero. The mandatory-completion guarantee thus extends to chains — software that stages N entries collects N records, always. Fire-on-success-only is deliberate (the io_uring rule): no conditional chains, no failure-path chains — that road leads to a hidden programming language in the queue machinery.

**`AUTO_REARM` — self-sustaining timers.** When an entry with the AUTO_REARM flag completes with **timeout**, the RBC re-reads and resubmits it. Combined with §6.3, this makes the architectural timer stage-once: arm with one doorbell, tick forever, disarm with one store that clears the flag (at most one already-in-flight tick follows — a bounded, benign race). The mechanism keys on completion status alone; aimed at a routable target it becomes retransmit-until-acknowledged, permitted but subject to §6.1's copies-not-messages caveat. AUTO_REARM takes precedence over LINK on the same entry: a rearming entry's chain awaits its next attempt rather than cancelling.

**The transistor budget, stated honestly.** Both mechanisms reuse the SEND-accept datapath and the descriptor-fetch path the RBC already has; the incremental silicon is a status comparator and a second address source. Everything that *scales* — chain topology, payloads, timer parameters, how many chains exist — lives in software-visible memory. Memory is transistors too, but shoved somewhere better: inspectable, per-actor, capability-guarded, and free when unused. That is the trade this architecture makes everywhere, made once more.

**Not adopted, recorded for honesty.** `AUTO_REPOST` (hardware re-enqueue of consumed landing buffers at CQPOP time) measured flat on cycles; it is *permitted* as an implementation feature — its real value is making the missed-repost bug class unrepresentable — but no software may require it. `MAC` one-byte vectored calls remain a sketch with data attached. Delivery-triggered ack templating (`ECHO`) was rejected outright: an ack only hardware saw is exactly the ack the end-to-end argument says nobody should trust. The full measurement ledger lives in the implementation record.

---

## 5. Execution Model: Continuations and the Hardware Scheduler

### 5.1 Contexts as Actors

A **context** is a near page, a run-queue entry, and a control block (§2.2 — the registers are shared burst-scratch). Each context owns at least one queue pair and one PTT-visible address — which makes each context, precisely, an actor: private state, an inbox, an address, and asynchronous sends. Section 5.4 completes the correspondence: actors can also be *supervised, restarted, and bounded*.

### 5.2 The Continuation Queue

The core maintains a hardware run queue of **continuations** — (context, incarnation, IP) triples ready to execute. The scheduling primitives:

- **`CONT addr`** — push a continuation onto the run queue.
- **`LSTN desc`** — park the current context until the descriptor's ring has data (or hits its watermark), then resume at the following instruction. Parking is free: the context simply leaves the run queue.
- **`YLD`** — voluntarily rotate to the next runnable continuation.

When any instruction would block — `LSTN` on an empty ring, `SEND` on a full SQ — the core proceeds to the next runnable continuation at zero cost (§2.2: there is nothing to save). A 6564-Net core with pending work never stalls on I/O. There is no busy loop anywhere in the model; the concept does not exist.

**Contended `LSTN` (v2.6, normative).** An `LSTN` that finds its ring
*non-empty* takes the hot path — continue in place — **only if no
other live context on this core is runnable**; otherwise it rotates
exactly as if it had parked, resuming past the `LSTN` in run-queue
order. Rationale, measured: on-chip delivery (4 cycles) beats a tight
serve loop back to its `LSTN`, so without this rule a self-messaging
actor's slices fuse into one unparked burst and an unwatchdogged
neighbor starves *invisibly* — no budget burned, no fault, no trace;
precisely the species of failure this architecture exists to
exterminate. The check is one comparison against run-queue state the
scheduler already holds; the rotation decision is a pure function of
that state, so bit-exact replay is untouched; and the measured price
across the entire benchmark corpus is **zero cycles** — the collapse
made rotation free, so fairness costs one honest branch. Hot-path
delivery is a privilege of an idle core.

### 5.3 Fairness and Real Time

The scheduler is round-robin by default with an optional per-context priority nibble. Because contexts are cheap and switches are single-cycle, real-time guarantees reduce to counting cycles within a context — the same discipline 6502 programmers used, recovered at 64 bits.

### 5.4 Supervision and the Watchdog

Actors fail. The architecture makes failure *observable, attributable, and recoverable* with three small mechanisms — the hardware skeleton of an OTP-style supervision tree.

**Exit links.** Each context may carry an exit link: a (supervisor context, CQ slot) pair, set by privileged software. On halt or fault, hardware posts an **exit completion record** to the supervisor's designated CQ — tag `exit`, status carrying the halt/fault code, cookie carrying the (context id, incarnation) of the deceased. Death is a message, delivered through the same CQ machinery as everything else.

**`SPWN` — restart.** `SPWN nblk` (near-page operand; `nblk,X` for indexed spawn-block tables) points at a 32-byte **spawn block** — `{target context, entry IP, stack pointer, argument}` — one of the architecture's near-page nouns, like a ring descriptor. Hardware resets the target's registers, loads SP from the block, delivers the argument in A (per-actor configuration typically travels as a pointer to a config block), increments the target's **incarnation counter**, and queues a continuation at the entry IP. The target's near page and exit link **survive** the restart — identity and supervision persist across lives. Run-queue entries carry the incarnation number, so continuations belonging to a dead life are skipped at dispatch: a restarted actor cannot be haunted by its predecessor's pending work. `SPWN` of self, or of an out-of-range context, faults the *spawner*.

**The watchdog burst budget.** Exit links catch actors that die; they cannot catch actors that *hang*. A context spinning in a pure compute loop under cooperative scheduling starves its whole core — including the supervisor that would otherwise restart it. The remedy is one comparator: each context may carry a **burst budget** in cycles (0 = unbounded), set by privileged software and surviving `SPWN`. The check runs between instructions; a context that exceeds its budget within one scheduling burst faults with code `watchdog`, and its exit link fires like any other fault. Instructions remain atomic — the trip lands after the instruction that crossed the line. The hang becomes an ordinary, supervisable death.

**`WDEX ##n` — declared long bursts (v2.6).** Some work legitimately
exceeds the base budget. A naive "feed the dog" instruction is
rejected — a hung loop containing the feed defeats the watchdog
exactly where it is needed — so extensions are *supervisor-bounded*:
the control block (§3.3) carries a privileged **declaration ceiling**,
and `WDEX ##n` sets the current burst's remaining budget to `n`,
faulting the declarer with `wdex_ceiling` if `n` exceeds the ceiling.
One declaration outstanding at a time (a second replaces, still
checked); `##0` cancels; with no watchdog armed there is no leash to
extend and the instruction is an architectural no-op. Everything
resets to the base budget at the next park. Semantics that matter and
are normative: **the budget runs on the dispatch clock** — a burst
that never parks keeps accumulating, so an armed watchdog eventually
trips even a loop that `LSTN`s hot forever — and declarations are
visible in code and auditable in trace. Language note, from the
measured campaign: a compiler that bills instructions from this
document's cycle tables can *check* declarations — reject
understatement, require declaration exactly when the computed bound
exceeds the budget — leaving the watchdog judging only data-dependent
extents. joe does; the only lies left are about data.

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

**Warning — never point hardware at hardware's own buffer.** The same family, from the other end. A submission whose payload address lies inside a receive ring's landing space is a race with the RBC: an `AUTO_REPOST` buffer is re-granted as its delivery is popped, so the bytes may be overwritten before the outbound datagram is formed. The rule is one line — *forward a payload by copying it into memory you own, never by pointing at where it landed* — and it is not a simulation artifact: it is what buffer ownership means when both ends of a copy belong to the fabric. (Found by a joe program forwarding a device reply straight from its landing buffer; the compiler now stages the copy, and the loss it caused looked exactly like a lossy network, which is the dangerous part.)

**Registered regions (v2.6).** The same one rule, widened from one
transmit buffer to one span of memory, composed entirely from
mechanisms this page already had — **the descriptor table is the
region table**:

- A **region descriptor** is an ordinary near-page descriptor carrying
  the REGION flag: word 0 the base, word 2 the length in bytes, word 3
  the capability token (§6.4). It lives beside the actor's rings,
  staged by the actor's own init, idempotent across respawn.
- **Grant-on-submit.** A request to an accelerator (§7.6) names the
  region's descriptor slot and presents its token; acceptance sets the
  descriptor's **OWNED flag** — the region is hardware-owned, and the
  §6.2 store rule applies to all of it.
- **The completion record is the release fence**, unchanged: hardware
  clears OWNED before the record lands.
- **Revocation is one store**: the owner zeroes its own token word.
  Every device access re-reads the *live* descriptor — the
  deferred-read discipline — so a late DMA against a revoked region
  **reject-completes and moves nothing**. This is the fencing story
  DMA designs usually lack: revoke a wedged accelerator and its late
  writes cannot scribble on reclaimed memory. Exercised in the suite
  in the honest window (revoke *after* the transport ack — the ack is
  the acceptance — and before completion).
- **Remote reads become legal here.** A remote or software
  implementation *pulls the region through the network window with the
  same token* — the future the PTT `write` right was explicitly
  reserved for. v0.1 made remote loads fault because there was no
  ownership story; this is the ownership story.
- **The `$6772` family.** Region business arrives on the ordinary RX
  ring, marked by the architected value **`$6772` in the low 16 bits of
  word 0** — outside any application tag space, so language runtimes
  route it without devices ever knowing an application's message
  vocabulary. The **kind byte at bits 24..31** says which member it is:
  kind 0 a **grant completion** (status at bits 16..23, the region's
  slot in word 1); kind 1 a **grant record**, the estate itself
  (§6.4). *The mark must be in the low 16 bits, and the requirement is
  not stylistic.* A receiver's tag test masks that half, and tags are
  handed out from 1 upward; a family member marked anywhere else is a
  number that collides with somebody's first message. v2.6 shipped the
  grant record as `$6772_0001` — the mark in the half nothing masks,
  and tag **1** in the half everything does — so heirs handled their
  own inheritance as an ordinary delivery, reading a descriptor slot as
  a message field, in silence. **A guard written in the wrong half of
  the word is not a weak guard; it is a different value that happens to
  contain the right bytes.**
- **Saturation is backpressure, never corruption**: a busy accelerator
  — or a grant of an already-OWNED region — reject-completes at the
  sender, and the first job completes bit-exact. Same law as the
  fan-in flood.
- **Streaming reuse** needs no new mechanism: a ring of region
  descriptors double-buffers exactly as queue-pair discipline always
  did. Coherence stance inherited unchanged: no coherent shared
  mutable memory; ownership handoff with the completion as fence;
  implementations flush/invalidate at grant and release.

A second consequence of hardware-managed landing: **delivery consumes the receive buffer regardless of whether software wants the payload.** A receiver that inspects a delivered datagram and discards it (a stale duplicate, say) must still re-post its landing buffer; accept/reject is the application's decision, but consumption already happened in hardware. The robust idiom is to repost on every `ok` delivery completion, wanted or not.

### 6.3 Timers: the Fabric as Clock

The ISA defines no timer peripheral, and needs none. The mandatory-completion guarantee of §6.1 *is* a clock:

**A `SEND` addressed through an unroutable PTT entry is the architectural timer primitive.** The datagram vanishes; the timeout completion record arrives on the local CQ exactly `send_timeout` cycles after acceptance. Software arms a timer by sending into a black hole and disarms it by ignoring the completion when it lands.

This is normative because it is load-bearing: over an unreliable fabric, the "request acknowledged, reply lost" case leaves a correct sender with nothing outstanding and nothing ever arriving — an unrecoverable park unless something wakes it. The fabric's honesty about its own timeouts is that something. Retransmission timers, retry-with-delay loops, and watch-timers for lame-duck shutdown phases all reduce to this one idiom, at zero silicon cost.

With §4.3's `AUTO_REARM`, the idiom is stage-once: an auto-rearming entry aimed at a black hole ticks forever. Arming is one doorbell; disarming is one store; every tick remains visible in the CQ, because a clock you cannot observe is not an honest clock.

**Discipline — a liveness-bearing timer must be `AUTO_REARM` (v2.6).** §4.2's overflow rule classifies a timeout as a *verdict*, droppable when a CQ is transiently full, on the grounds that verdicts are re-derivable. That reasoning holds for an auto-rearming timer — the next tick re-derives the wake — and **fails for a one-shot**, which has no next tick. A dropped one-shot timeout is the eternal park coming back through the side door: the actor pops what it can, finds no work, re-parks with nothing outstanding, and waits forever, data-dependently. So: a timer whose completion is the only thing that will ever wake its actor is staged `AUTO_REARM`; a one-shot timeout is an ordinary verdict and enjoys no protection. The corpus already obeys this — compiled `after` timers and every hand-written timer stage the flag — and a test now holds it there.

Open details (§11): whether `send_timeout` is per-send, per-PTT-entry, or global; whether a standardized black-hole PTT slot should be architecturally reserved; and whether the RBC should *reclassify* rather than rely on discipline — it knows at submission time that a route is unroutable, and a timeout from an unroutable entry describes no copy's fate. Nothing was ever going to arrive: it is a message to yourself from the future, delivery-class by nature. That would close the side door in silicon instead of in a style guide.

### 6.4 Capabilities

Any memory reachable from a network is memory that must defend itself. The 6564-Net adopts the RDMA answer, enforced in hardware:

- Every PTT entry and every ring descriptor exposed to remote access carries a **64-bit capability token**.
- Inbound operations must present a matching token; the RBC checks it before any byte moves. Failures post a reject completion to *both* ends and move no data.
- Tokens are minted and revoked by privileged software. Revocation is immediate: clear the descriptor field.

This composes naturally with capability-based operating systems — a PTT entry *is* a capability in the object-capability sense, and the OS's capability graph maps directly onto silicon-enforced reachability.

**The rights word is two fields, and they check differently (v2.6).** Conflating them is the mistake this section exists to prevent:

| field | what it says | check | attenuable |
|---|---|---|---|
| **dialect** | what the endpoint **is** — `raw` sink, `msg` actor, `ask` device (§7.3) | **equality**, at accept | **no** — a weakened dialect is nonsense |
| **verbs** | what the holder **may do** — read, write, send, and `grant` (reserved for transfer) | **subset**, at accept | yes — that is what attenuation means |

A submission carries a **claim** of what its payload is (the SQE's reserved hint word; a register send claims `msg` by construction, since one cannot print a register). The RBC compares claim against dialect one step after the rights test, on the path that already checks tokens — measured at **zero cycles**, the frozen tables byte-identical. Mismatch is a capability-family reject: both ends told, no bytes moved. This is what makes the §7.3 misdirection hazard unrepresentable — a `msg` image at an `ask` device would have the device read a message tag as a reply window *in its own PTT space*, synthesizing a wild capability out of a number.

**A region capability may not leave its memory domain (v2.6).** Verbs
attenuate by subset and dialects compare by equality — and a region
carries a third property that does neither: the **domain** its base
address is meaningful in. RAM is per-core, so a region descriptor names
a span of *one core's* memory. Carried across a core boundary the
capability stays perfectly well-formed — right length, correct verbs,
freshly minted token — over memory the grantee never named, which is
the worst possible failure shape: nothing is malformed, so nothing
complains. The RBC therefore refuses a transfer whose source and
destination domains differ, at the source, before minting. Succession
is a movement *within* an address space; carrying a span across one is
a copy, and a copy is a different operation that must be asked for by
name. The general principle is the one dialects taught: **a boundary
that holds because the two sides have different domains is structure,
and structure has to be checked somewhere.** Here the domains are
literally memory.

**`any` is unset, not top.** A dialect field may read `any`, meaning *no declaration was made*: a loader-era entry, wired before the field existed or by a loader with nothing to say. Its checks are **skipped, not satisfied**. This is deliberate and it is not a lattice: `any` is not a permissive value that concrete dialects refine, so replacing it is not attenuation — there is nothing there to attenuate. Two consequences follow, both load-bearing for capability transfer: **a derived entry may never carry `any`** (minting a capability is precisely when the grantor must state what it is for), and `any` is therefore scaffolding that transfer cannot propagate — it ends where the static wiring ends.

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

**The echoed tag (Amendment 3 addendum).** Every asking device's request begins with a **caller-tag word**: silicon never interprets it and echoes it verbatim as the reply's first word. This is the accelerator contract's reserved word (§7.6), generalized to the whole row — the machine shipped the convention twice before it was named. The reply wears the tag you gave it, so a serve loop can match a device's answer exactly as it matches any message; an untagged raw answer no longer exists on the row. Uniform ask framing: word0 = tag, word1 = reply window, device arguments from word2; uniform reply framing: the echoed tag, then data from +8. Devices that never answer — the console is a raw sink, payload-is-text — carry no tag word: a sink has nothing to echo. Devices that *push* unasked (a pad, a display's vblank) are the same convention minus the request: their contracts name their tags.

**The reply window is the request for a reply.** Word1 is not decoration on operations that had nothing to say: a device answers **when, and only when, the request leaves a valid return address**. A block write with a window word echoes the tag once the sector is the caller's; the same write with word1 zero says nothing, and the fabric ack remains the whole receipt, exactly as before. This is not politeness — it is the only **sequencing point** available to a driver that cannot read transport verdicts. Such a driver exists by construction: a compiled joe actor never sees an ack, so without an answer it cannot know its write landed before its read-back departs. One rule, two audiences: *leave an address, get an answer.*

**Raw replies carry no in-band framing; the fabric already counted.** A device's payload has no length byte and no terminator. The completion record's count field is the length — it is written by the same hardware that filled the buffer, and inventing a second copy inside the payload would only create something to disagree with. A tag-only reply (count = 8) therefore means "nothing to report, ask again", and a reply with data means data: the receiver subtracts the header from the count and has its extent. Software that wants a self-describing payload is free to put struple in it (§7.5 says protocol lives above the contract), but the row itself frames nothing.

### 7.4 The v1 Device Set

Defined for the reference simulator; the set is open, the conventions above are not.

| Device | Row coordinate (convention) | Contract |
|---|---|---|
| `console` | `$FF00` | Payload bytes are text, appended to the world. No reply, no tag: the delivery ack is the receipt, and `SEND` is `PRINT`. |
| `entropy` | `$FF01` | Request {tag, reply window, count}; replies {tag, `count` seeded-deterministic random bytes}. Same seed, same universe — still. |
| `rtc` | `$FF02` | Request {tag, reply window}; replies {tag, the fabric cycle at which the request arrived}. §6.3 gives software intervals; the RTC gives it timestamps. |
| `block` | `$FF03` | Request {tag, reply window, op \| sector, data…}. A write applies at delivery — the fabric ack **is** the write ack. A read sends {tag, the sector} to the reply window. Both idempotent by construction. |
| `net` | `$FF04` | The raw byte pipe to real TCP — open {tag, reply window, op, port, host} → {tag, connection id}; send bytes (the ack is the write ack); recv {tag, reply window, op, max} → {tag, 0..max bytes}, where a TAG-ONLY reply means "ask again" and a REJECTED request means EOF: the ack vocabulary is the framing. No protocol opinion — that lives in §7.5. |
| `matmul` | `$FF05` (in-proc), `$FF06` (remote polyfill) | The first accelerator actor (§7.6): request {reserved word, region slot, token, M\|K\|N, three in-region offsets}; C ⟵ A·B inside the granted region; completion via the `$6772` convention. Declares `deterministic`: k ascending, IEEE RNE — the two implementations agree to the bit. |
| `display` | `$FF07` | The frame clock (§7.7): request `Present {reserved word, region slot, token}`; the granted region is presented and returned one vblank interval later as `PresentDone` (the `$6772` completion). Single-buffered — a second `Present` in flight is refused; the backpressure *is* the frame rate. |

An off-die network bridge is the row's natural fifth citizen: a NIC is just another device. As of v2.4 the plane beneath it is architectural (§6.5) — multi-die topologies arrived as an extension, not a redesign — and as of v2.5 the `net` device is the pipe off the board entirely.

**The determinism scope.** The `net` device is the one place wall-clock reality enters: the outside world does not replay. A machine with no `net` attached replays bit-identically as always; a machine with one replays everything except what the world said and when. The boundary is exactly the device contract — nothing inward of it ever observes real time.

### 7.5 Protocol Stacks: Silicon Is an Optimization

Devices are actors made of different silicon (§7) — and the converse is the load-bearing half: **through the fabric, a client cannot tell which one it got.** A capability names something that answers messages; whether that something is gates at a row coordinate or an ordinary 6564 context running the same protocol in software is a *deployment decision, not an architectural one*.

This makes the polyfill principle normative: **a device contract is valid only if an ordinary actor could implement it.** Contracts may use only the message vocabulary actors already have — request/reply windows, capability tokens, acks, idempotent retry. This is why MMIO and interrupts were never allowed into §7: they would have made silicon an interface instead of an optimization. The principle is testable, and implementations should test it: run a contract's suite against the silicon device and against its actor polyfill and demand identical client-visible behavior.

Protocol stacks then layer without new architecture: the `net` device is a byte pipe with no opinions; HTTP, WebSockets, TLS are **protocol actors** above it — specified as device contracts, shipped as silicon where it pays and as 6564 code where it doesn't, promoted or demoted between the two without any client noticing. (Precedent, gratefully inherited: Erlang callers cannot tell a C port from a process, and Unix made everything a file descriptor. Here the same move is capability-gated and location-transparent.)

**The numeric addendum (v2.6, normative).** Without it, "no client can
tell" is false *at the bits* for any device that computes. Every
device contract that produces numbers carries an explicit
**`deterministic` flag**:

- **Set**: the contract specifies exact arithmetic *including
  reduction order*. Implementations must agree bit-for-bit; the claim
  is polyfill-checkable and replay-safe across implementation
  substitution. (The matmul contract is set: k ascending, IEEE RNE —
  and the suite drives both implementations with the same program,
  differing by one PTT binding, demanding identical bytes.)
- **Clear**: results are contract-accurate but implementation-varying.
  Replay is guaranteed **per-federation** — same seeds, same devices,
  same bits — but not across device substitution.

The application programmer decides whether the difference matters and
chooses mitigations (deterministic devices, polyfill verification,
tolerated variance). The machine never pretends two accelerators agree
when they don't — bit-identical replay is the crown jewel, and the
first parallel reduction would quietly break it without this flag.
Inside the ISA the bar stays absolute: Tiers 0–1 are bit-exact by
definition (§8.1), reduction shapes included.

### 7.6 Accelerator Actors (v2.6)

Large operations — matmul today; splat math, inference pushes
tomorrow — are **fabric requests**: the core grants a region (§6.2)
with the submission, parks or proceeds, and handles the completion
like any other delivery. A discrete accelerator, a GPU compute path,
and a software polyfill are indistinguishable per §7.5 — the
reference implementation proves it with gates-vs-window-pull twins
that agree to the bit. Silicon is an optimization, never an
interface; now with numbers attached.

### 7.7 The Display: a Completion Is a Clock (v2.6)

A display is an accelerator (§7.6) whose work is to *present*. A core
grants it a frame region — `Present {reserved word, region slot,
token}`, the accelerator submission minus the dimensions, because a
display does not compute, it shows — and the region is hardware-owned
(§6.2) from the submission until the completion. One vblank interval
later the display returns it: `PresentDone`, the ordinary `$6772` grant
completion, which rebinds the region and hands the frame back.

The consequence is the whole point. **Nobody calls a 6564 actor**, so a
frame loop cannot be a platform calling `update()` sixty times a second.
It is backpressure: a core cannot draw again until the display returns
the region, and a single-buffered display returns it exactly once per
frame. The completion *is* the frame clock; the grant *is* the pacing.
A second `Present` while a frame is up is refused — saturation is
backpressure, per §5.4 — and at the language level it cannot even be
written, because the region is type-state-locked between grant and
completion (§6.2): the runtime refusal is the early static check's twin
(§2.3). The double buffer is not a queue the display grows on the
program's behalf; it is two regions the program alternates, two grants
in flight against two frames, the display still single-buffered per
region. A frame's worst-case cost is priceable against the ISA table
(every sprite a constant extent), so a display contract can be certified
never to miss its vblank by surprise — the arithmetic lies die at
compile time, and a game has no data lies to tell.

This is the peripheral row's second *pushing* device by nature (§7.1,
the line that named "a display's vblank"): the completion arrives unasked
in the sense that no `RECV` solicited *this* frame's return — the grant
did, one frame ago. Determinism is total inward (§7.4): the frame the
glass receives is the frame the core drew, checksum for checksum.

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
| `SPWN` | Restart a context from a near-page spawn block {ctx, entry, SP, arg→A} (§5.4): incarnation bumped, continuation queued. Near page and control block survive; there are no banked registers left to reset (§2.2). | `SPWN nblk` / `SPWN nblk,X` |
| `CAPLD` | Privileged: load a PTT entry (prefix, rights, capability token). | `CAPLD slot, (ptr)` |
| `WDEX` | Declare the current burst long: set its remaining watchdog budget to n, ceiling-checked against the control block (§5.4). `##0` cancels; no-op without an armed watchdog. | `WDEX ##n` |

Descriptor operands (`desc`) are one-byte near-page offsets. The general-purpose instruction set (loads, stores, arithmetic, branches) follows the 6502 pattern language — including indexed and indirect modes — widened to 64 bits, and applies uniformly to local and network-window addresses.

### Encoding Note

Instructions remain byte-granular and variable-length in the 6502 tradition: one-byte opcodes, with operands sized by addressing mode. Inherited 6502/65C02 instructions retain their classic opcode bytes; new I/O and concurrency operations occupy columns NMOS never defined. Near-page modes keep the hot path (queue ops, continuation ops) at 2–3 bytes per instruction. Code density is a stated goal: instruction fetch is a bandwidth consumer like any other, and a message-passing machine should not spend its bandwidth describing itself.

**Counted shifts (v2.5).** `ASL/LSR/ROL/ROR #n` occupy the `$?B` column: a 64-bit machine extracts fields, and eight-line single-bit shift ladders were instruction burn with no silicon justification — a barrel shifter is constant-time, so any count costs 2 cycles. Count is taken mod 64; count 0 is a no-op that preserves the flags; carry is the last bit shifted out, exactly as n single-bit shifts would leave it. The bare single-bit forms keep their classic bytes and behavior.

### 8.1 The Extended Page and the FP Tiers (v2.6)

One prefix byte — **`$42`**, WDM, the byte the 65816 reserved for
expansion and never spent — opens a second 256-entry opcode page.
**Non-stacking, hard rule**: `$42` is undefined *on* the extended
page, so a second prefix is an honest fault, not a deeper decode. The
Z80's DD/CB prefix soup is the cautionary tale; decode stays countable
and the assembler stays honest.

**Tier 0 — scalar FP, no new registers.** FP64 lives in A as its bit
pattern; FP32 widens on load (`FLDS`) and narrows on store (`FSTS`).
`FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/FTOI/ITOF` occupy their integer
analogs' rows on the extended page. Numerics, binding: IEEE-754,
round-to-nearest-even, **no FTZ/DAZ, no silent fusion** — bit-exact
deterministic, inside the §5 determinism bar. `FCMP` speaks the flag
dialect (Z equal, N less, C greater-or-equal; unordered raises V
alone — a NaN comparison is a fact, not a fault); `FTOI` truncates
toward zero, saturates out-of-range and converts NaN to 0, raising V
for both. Oracle-verified: a Mandelbrot rendered on the machine
matches host arithmetic character-for-character across ~40,000 FP
operations, so one misrounding is a visibly wrong pixel.

**Tier 1 — the vector unit, on the `$?7` column.** The base page
spent its `$?7` column on I/O and concurrency; the extended page
spends its on vectors: `VLD/VST` (64 bytes at the address in X — no
new addressing modes), `VBCA` (broadcast A), lanewise f64 and u64
arithmetic (priced as the scalar ops: eight lanes are parallel
silicon, not eight passes), `VPERM` (lane indices ride in A, one byte
per lane), and three reductions. **Reduction order is part of the
contract**: `VRADD` is the pairwise tree
`((l0+l1)+(l2+l3))+((l4+l5)+(l6+l7))` — one shape, always, proven in
the suite *by distinction* from a sequential fold; `VRMAX/VRMIN` fold
sequentially with lane-0 tie bias and one canonical NaN. Two-register
forms pack `(d<<3)|s` into the operand byte. Measured: a 256-element
dot product runs **6.4×** the scalar loop, both bit-exact against
their own declared orders — and honestly different from each other,
because they *are* different declared orders.

### 8.2 MAC — Adopted as Optional, with Its Numbers (v2.6)

The `$?F` column's one-byte vectored calls (`MAC n` = JSR through the
per-context MACTAB at near `$F80`) were deferred in v2.2 for lack of
reuse. Compiled code supplied the reuse: an actor that writes the same
byte-comparator twelve times collapses to **−31.4% code at +3.0%
cycles** when sites route through shape-specialized MACTAB routines.
The 3% is call linkage plus per-burst stack re-establishment — under
§2.2, SP is park-volatile, so a burst that calls must first aim the
stack (two instructions after each wake). MAC is therefore adopted in
AUTO_REPOST's category: **a permitted optional feature**, opt-in per
deployment where code density pays for cycles. The larger prize — one
comparator shared across a core's actors — requires a shared-code-
pages story and stays in §11.

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

Cycle-stepped virtual clock, fully deterministic from a seed; contexts with near-page descriptor tables (register banking retired by the v2.6 collapse); the continuation queue and cooperative scheduler; single-core queue pairs.

### Phase 2 — Virtual Network Mesh: **complete**

Multi-core with PTT routing; seeded latency, jitter, loss, reordering, and duplication on off-chip paths — acknowledgments included, so the two-generals problem is live in every run. Deterministic replay is verified by test: any observed failure reproduces bit-identically from its seed.

### Phase 3 — Actor Workloads: **complete**

The three representative workloads all run, built entirely from CQ feedback and the primitives of §5–§8 — no ISA additions were needed beyond §5.4's supervision pair:

- **Ping-pong** with full end-to-end reliability over lossy fabric — retransmission timers via §6.3, sequence checking, duplicate handling.
- **A one-for-one supervision tree** — exit links, `SPWN` restarts with per-child budgets, and watchdog-caught compute hangs (the full arc: hang, trip, restart, budget exhaustion).
- **Pipeline dataflow** across N cores — per-hop stop-and-wait with ack-on-ownership overlap, backpressure by silence, and a lame-duck shutdown phase; every item checksum-verified through 73% loss.
- **Scatter-gather** (bonus workload) — idempotent workers, straggler re-scatter, no acknowledgment protocol at all: the result is the ack.

### Measured Claims

- **60 cycles per message pass** on Armstrong's ring (§2.2), flat across two orders of magnitude of scale, regression-guarded.
- 200 complete actors (near page + control block) on one core, with room to spare — and that figure predates v2.6: it was bank-bound, and the bank is gone (§2.2). What a context costs now is its near page and its leash; the ceiling wants re-measuring against memory, not against a register file that no longer exists.
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

### The Capstone (v2.5)

`sim6564 web` — `programs/asm/http_get.asm`, a 6502-descendant assembly program, speaks HTTP/1.1 through the `net` device and fetches `http://example.com/` from the actual internet: 869 bytes of Cloudflare-served HTML on the teletype, 784 instructions, clean halt. The protocol lives entirely in 6564 code (§7.5's polyfill layer at its simplest); the device knows only bytes. Test coverage is hermetic — the suite runs the same program against a local TCP server. One driver lesson joined the record: a shared staged SQE is mutable state — set every field you depend on, every submission (a stale target field once sent a recv request to the teletype, which printed it, politely, forever).

### The joe Campaign (v2.6)

Everything this revision normativizes was measured through **joe**,
the architecture's language (Go's clothes, Erlang's soul, occam's
discipline; `docs/joe-v1-sketch.md` and its two amendments), whose
compiler is the §2.2 experiment made executable: `var` is the near
page, `serve` is `LSTN`→`CQPOP`→dispatch, `after` is the §6.3 timer,
and what joe *cannot* say — shared state, synchronous calls,
transport-ack visibility, touching a granted region, undeclared long
compute — is the specification's negative space enforced at compile
time. Highlights, all regression-guarded (full ledger in
`docs/measurements.md`):

- **The collapse, priced**: compiled ring 110 → **55.26 cy/pass**
  (hand: 60); the whole corpus cycle-identical under `scorch`
  (registers poisoned at every park). Compiled code is *stack-free* —
  even SP owes the parks nothing — except opt-in MAC linkage, which
  re-establishes SP per burst and is priced above.
- **Contended LSTN, priced**: zero cycles across the corpus; the
  starvation it prevents is a regression test in both directions.
- **Checked `bounded`**: the compiler bills every emitted instruction
  from the ISA cycle tables (both pages); understatement is a compile
  error; the watchdog judges only data-dependent extents.
- **A thousand-actor fork-join tree** (1,009 contexts) joins to the
  exact sum at 25% loss + duplication; a 4-slot key-value store —
  canonical struple keys, byte-equality dispatch — serves
  Put/Get/Del as an ordinary actor, discharging §7.5's proof
  obligation for the store contract before any store silicon exists.
- **Tuple bytes are conformant**: the joe/6564 struple codec is that
  format's thirteenth implementation, proven against the shared
  corpus *on this machine, under scorch* — pack byte-identical,
  skip total across the full type tower including types the subset
  cannot decode.
- **Regions end to end**: grant, park, rebind; revocation in the
  honest window (after the ack, before the completion)
  reject-completes without a scribble; both matmul implementations
  agree to the bit behind one PTT binding.

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
4. **Timer parameters (§6.3)** — is `send_timeout` per-send, per-PTT-entry, or global? Should an architecturally reserved black-hole PTT slot exist so timer code is portable? **Joined in v2.6 by the timeout-classification question**: §4.2 calls a timeout a verdict (droppable), but §6.3 is the one place a verdict is promoted to load-bearing, so a *one-shot* timeout is liveness that the overflow rule does not protect. v2.6 answers with discipline (`AUTO_REARM` for anything liveness-bearing). The silicon answer is a reclassification the RBC can actually make — it knows at submission whether the route is a black hole, and a timeout from an unroutable entry describes no copy's fate, which makes it delivery-class by nature rather than by convention. It belongs in this cluster because it is the same "what does the black-hole slot mean architecturally" question wearing a third face.
5. **SQ drain-rate modeling** — v0.1's RBC drains submission queues instantly, so "`SEND` parks on full SQ" is defined but unexercised. Chain fires (§4.3) give the RBC its first architecturally visible non-instant work, and are the natural seam for a drain-rate model.
6. ~~**CQ overflow**~~ — **Resolved in v2.6 (§4.2): the guarantee is conditional on capacity, and the failure is supervisable.** Verdicts drop and count (re-derivable); deliveries and exits fault the owning context so the exit link fires. An io_uring-style side-channel remains available as a future refinement for software that would rather see the loss than die of it — but nothing is silent any more, which was the actual defect.
7. **Peripheral discovery** — v2.3 binds device capabilities statically at load time, like everything else the loader wires. Whether enumeration ("what lives on this row?") is an architectural protocol or purely a software convention is undefined.
8. ~~**Off-die bridges and multi-die time**~~ — **Resolved in v2.4 (§6.5): the route selector and the IO plane.** The conservative synchronization contract (window = plane minimum latency) is normative-by-consequence and validated: the reference simulator runs one die per host thread, bit-identical to sequential at any thread count. Remaining sub-question: route selectors are per-PTT-entry and loader-assigned; whether route discovery/topology description deserves architectural surface belongs with question 7's discovery story.
9. **Capability transfer (`.from`)** — a reply target is a capability
   in the *receiver's* PTT space, and a sender cannot name it. Reply
   routes are static wiring today (joe deliberately has no `.from`).
   First-class capability transfer — with a paper trail — is the
   kernel's first real requirement, and it is the same question as
   region sub-grants and as key-range migration (the D1 note in
   Amendment 2): three costumes, one mechanism, undesigned.
10. **Exactly-once device framing** — a duplicating fabric plus a
    device with no dedup (a teletype) prints twice. Proposed shape:
    device contracts default to exactly-once framing and *declare*
    relaxation, mirroring the `deterministic` flag's honesty. Undecided.
    Note the structural asymmetry the echoed tag (§7.3) exposes: a
    device that answers has a caller tag to dedup *by*, while a
    tag-less sink has nothing to compare — the console cannot dedup
    even in principle, so under "exactly-once by default, declare
    relaxation" it is the first and most certain declarer. Any framing
    that pretends otherwise would be asking sinks to keep state they
    were defined not to have.
11. **Shared code pages** — the MAC re-trial's ceiling: MACTAB is
    per-context, so routine reuse stops at the actor boundary. Demos
    already run many actors from one program image; whether shared
    read-only code pages (and cross-actor MACTAB conventions) deserve
    architectural surface would multiply MAC's −31% across a core.
12. **Unparked-burst ceiling for the unwatchdogged** — contended LSTN
    (§5.2) means an unparked hot loop can only exist on an idle core,
    where it harms nobody; and a watchdogged one trips on the dispatch
    clock. Whether an *unwatchdogged* context should also face some
    architectural ceiling on an unparked run — belt to those braces —
    is recorded as open rather than smuggled in.
13. **Vector width and lane forms** — V0–V7 × 512 earned its area on
    the first workloads (6.4× on dot-product; row tiles; SoA sets).
    f32 sixteen-lane forms, compare-to-mask with a select, and
    gather/scatter are deferred until workloads demand them: size to
    the workloads, not more.

---

*The 6502 proved that a small, honest machine could carry a revolution. The 6564-Net is a wager that the same virtues — tiny state, predictable behavior, semantics that never lie — are exactly what a planet-scale mesh of communicating actors has been waiting for. The receipts have compounded: fifty-five cycles a pass from a compiler that was told the truth about the machine; a register file that vanished because nobody could ever legally have read it; a thousand actors joining to an exact sum through a fabric that loses a quarter of everything; two matmuls that cannot be told apart except by the clock; and a language whose negative space — what it will not let you say — is this specification, enforced. Nothing in this revision was designed at the desk. It was all transcribed from the machine.*
