# Sketch: MAC Vectors & RBC Descriptor Chains

**Prototype design for sim6564 — pattern-collapse mechanisms atop the core ISA.**

*Companion to the 6564-net architecture spec and the sim6564 implementation record.*

> **Status: campaign concluded (July 2026).** Every mechanism was built and
> measured against the plan in §6; the ledger is in measurements.md. Adopted
> into spec v2.2 (§4.2–§4.3): the SQE format, `LINK` + `chain_cancelled`,
> and `AUTO_REARM`. Parked as optional: `AUTO_REPOST` (flat on cycles; its
> value is deadlock-class elimination). Deferred with data: `MAC` (this
> corpus can't feed it). Never built, as designed: `ECHO`. Three of five
> predictions below were wrong — kept intact, because that's the point.

---

## 0. Scope and Philosophy Check

Two mechanisms, two homes, zero decoder complexity:

- **`MAC n`** — one-byte vectored calls (RST / SWEET16 lineage). Lives in the *instruction set*; semantics are exactly `JSR`.
- **RBC chains and auto-flags** (io_uring linked-SQE lineage). Live in the *queue machinery*, where autonomous hardware behavior already legitimately exists.

Explicitly out of scope, permanently: descriptor-interpreted macro instructions in the decoder (writable microcode — the VAX road), and any hardware form of the dispatch loop (`LSTN → CQPOP → branch` is the actor's *behavior*; it stays in software).

Every mechanism below preserves the two load-bearing invariants: **cycle-countable execution** and **the CQ as the single, truthful source of I/O status**. Chained and automatic operations post completion records exactly like hand-issued ones; nothing hardware does on software's behalf is silent.

---

## 1. `MAC n` — One-Byte Vectored Calls

### 1.1 Semantics

`MAC n` (n = 0..15) is precisely:

```
JSR [MACTAB + n*8]
```

Push the return address, load the 64-bit target from macro vector slot *n*, jump. No hidden state, no interpretation. Cycle cost: `JSR` + one near-page load (constant, countable).

### 1.2 Vector Table

**`MACTAB` = near page `$F80`–`$FFF`**: 16 slots × 8 bytes, top of the software-scratch half. Per-context (the near page is private), so each actor names its *own* sixteen hottest routines — a supervisor's `MAC 0` and a pipeline stage's `MAC 0` can differ, even running the same shared code image, because the vectors travel with the context, not the code.

Uninitialized slot (zero) → fault the caller, code `bad_macro`. Honest: a `MAC` through a null vector is a bug, not a jump to page zero.

### 1.3 Encoding

One-byte opcodes in the **`$?F` column** (fully free in `isa.zig`): `$0F` = `MAC 0` … `$FF` = `MAC 15`. High nibble is the slot index — the whole column, spent on one feature, exactly the way the 6502 spent columns.

*(Erratum against the first draft: `$?B` is not free — `$AB` is `LDY ##imm64` and `$DB` is `HLT` in STP's homage slot. `$?F` has all sixteen. The bad-opcode canary test moves off `$FF`.)*

### 1.4 sim6564 Touch Points

- `isa.zig`: 16 table entries (declarative; assembler and docs come free).
- `machine.zig`: one execute arm (reuse the JSR path + near-page read).
- `asm.zig`: `MAC n` mnemonic; optionally `.macro name = addr` sugar that assigns slots and emits the table.
- Stats: `macro_calls`.

---

## 2. RBC Extensions: Entry Format First

The chain mechanisms need a defined submission entry. Proposal — **32-byte SQE**, same granularity as descriptor slots:

```
offset  field         width  notes
0       op            8      send / txr / recv / nop
1       flags         8      see §3; bit 7 = OWNED (the §6.2 ownership bit)
2       link          16     near-page offset of next staged SQE (0 = end of chain)
4       status_hint   32     reserved / debug
8       target        64     window pointer (PTT-mapped) — dest for send/txr
16      buf / value   64     buffer base (send/recv) or immediate value (txr)
24      len           32     bytes (send/recv)
28      cookie_lo     32     low half of cookie; high half stamped by hardware
```

Notes:

- `link` is a near-page offset, so chains are staged anywhere in the context's scratch region — 12 bits suffice; 16 keeps alignment simple.
- The §6.2 ownership bit is **flags bit 7**, set at accept and cleared when the completion posts, unchanged semantics.
- Hardware stamps the cookie's high half as **staging-slot[0..16) | incarnation[16..32)** — for ring-staged heads the SQ descriptor slot, for chain entries the near-page offset of the staged SQE. This kills two v0.1 sharp edges at once: completion records become self-identifying (which staged entry, which life), and a `SPWN`-restarted actor can't misattribute a dead life's completions. Software keeps 32 bits of cookie for its own identity (sequence numbers etc.).
- **Completion records gain a source-ring field**: word0 bits 16..24 carry the ring descriptor slot the record pertains to (bits currently reserved). AUTO_REPOST (§3.3) requires it — the RBC must know which ring a popped delivery belongs to — and software dispatching a mixed CQ gets cheaper for free.
- Ownership bit semantics (§6.2 of the spec) apply per-SQE, unchanged. The slot-reuse warning applies to *staged chain entries* with extra force: every entry in a chain is in-flight from the moment the chain head is accepted.

Ring-level flags (AUTO_REPOST) go in a **flags byte in the ring descriptor** (there's room in the 32-byte layout per `ring.zig`); entry-level flags (LINK, AUTO_REARM) go in the SQE.

---

## 3. The Flags

### 3.1 `LINK` (SQE flag) — success-chained submission

On **ok** completion of entry E, the RBC reads the staged SQE at `E.link` and submits it. Linear chains only; `link` walks until 0.

On **non-ok** completion of E (timeout, reject), the chain breaks: the RBC posts a completion record for *every* remaining staged entry with status **`chain_cancelled`** (new status code), payload count 0, cookies intact. This extends the mandatory-completion guarantee to chains — software that staged N entries always collects N records, and a broken chain is loud, not silent.

Semantics deliberately copy io_uring's link rule: **fire on success only**. No conditional chains, no failure-path chains in v0 — that's where a chain mechanism starts becoming a hidden programming language.

Cycle model in sim: chain-fire costs the same as a software `SEND` accept (charged to the RBC, not the context — the whole point is the context is parked or doing other work).

### 3.2 `AUTO_REARM` (SQE flag) — self-sustaining timers

For the §6.3 fabric-as-clock idiom. When an entry with `AUTO_REARM` completes with **timeout**, the RBC re-reads the staged SQE from RAM and resubmits it. The re-read is the disarm mechanism: software clears the flag bit in the staged entry (one near-page store) and the timer dies at its next firing — at most one extra completion, a benign and *bounded* race.

The demo's persistent timer chain (`send → timeout → CONT re-arm handler → send`) collapses to: stage once, forget. Each firing still posts its timeout record — the timer remains visible in the CQ, because a clock you can't observe isn't honest.

Re-arm fires on **timeout status only** — the mechanism keys on the completion's status, never on routability, which it cannot know. On an entry that completes ok (or rejected), `AUTO_REARM` does nothing. Consequence, stated plainly: an `AUTO_REARM` entry aimed at a *routable* target is a hardware retransmit-until-acknowledged engine. That is permitted but subtle — §6.1's copies-not-messages rule means a duplicate's reject can arrive instead of an ok and stop nothing, or an ok can arrive for a copy the receiver discarded. End-to-end correctness still belongs to software; the intended use remains the black-hole timer.

### 3.3 `AUTO_REPOST` (ring descriptor flag) — the receive idiom

For "repost on every ok delivery, wanted or not." On **`CQPOP` of a delivery record** from an RX ring with `AUTO_REPOST` set, the RBC re-enqueues the just-consumed landing buffer at the ring's tail.

The pop is the trigger — not the delivery — because delivery-time repost would let the next datagram overwrite a payload software hasn't seen. Pop-time repost gives a quantifiable validity contract:

> **After `CQPOP`, the payload remains valid until the ring's other N−1 buffers have been consumed by subsequent deliveries.**

This is the standard NIC-ring discipline, stated honestly. Consequences:

- `AUTO_REPOST` on a capacity-1 ring is architecturally meaningless (validity window = zero) → `bad_descriptor` fault at first use. Honest, like `RECV`-on-full.
- Software that must hold a payload across many deliveries copies it out — same rule as today, now with a stated bound instead of a convention.

This flag erases one `RECV` + bookkeeping per received message across every actor in every demo — almost certainly the biggest single win in §6's measurements.

### 3.4 Deliberately deferred: `ECHO` (delivery-triggered ack templating)

The pipeline's ack-on-ownership *could* go to hardware: an RX-descriptor-linked staged TXR whose payload is templated from the first 8 bytes of the delivered datagram (the sequence number). Sketched here for completeness; **prototype last, expect to cut it.** The demos taught that meaningful acks are application decisions (validate, then ack), and a transport-level auto-ack is exactly the ack the end-to-end argument says nobody should trust. If measurement shows the pipeline's ack path dominating instruction counts, revisit; otherwise this stays software.

---

## 4. New Status and Fault Codes

| Code | Kind | Meaning |
|---|---|---|
| `chain_cancelled` | completion status | Staged entry cancelled by an upstream chain break |
| `bad_macro` | context fault | `MAC n` through a zero vector |
| (existing `bad_descriptor`) | context fault | Extended: `AUTO_REPOST` on capacity-1 ring |

---

## 5. sim6564 Implementation Order

1. **SQE format** (`ring.zig`) — prerequisite for everything; migrate existing demos' staging to it. Pure mechanical churn, do it alone, get to green.
2. **`MAC`** — smallest diff, immediate density data from re-assembled demos.
3. **`AUTO_REPOST`** — biggest expected win; touches `CQPOP` path + RBC.
4. **`AUTO_REARM`** — collapses the ping demo's timer chain; good LINK warm-up since it shares the re-read machinery.
5. **`LINK` + `chain_cancelled`** — the real chains; port the pipeline's per-hop sequence to exercise cancellation under injected loss (the fault mesh will find the silent-break bugs for free).
6. New stats: `macro_calls`, `auto_reposts`, `auto_rearms`, `chain_fires`, `chain_cancels`.
7. Regression guards: ring benchmark must stay <100 cycles/pass with all features *unused* (the null cost of the mechanisms must be zero), plus one deterministic chain-break replay test.

---

## 6. Measurement Plan — the Go/No-Go

For each demo, before/after: `stats.instructions`, code bytes (assembler output), cycles to completion, and per-feature fire counts. All at fixed seeds; fault injection on.

Acceptance, per mechanism independently:

- **Adopt** into spec v2.2 if it removes **≥15% of executed instructions** in at least two demos, or ≥20% of code bytes overall (`MAC`'s likely case), with zero regressions in the §6-semantics tests.
- **Cut** if under 5% everywhere — the itch was aesthetic, and the sketch retires with its data attached.
- Between: park as an *optional implementation feature* alongside the macro-op-fusion note — permitted, not architectural.

Prediction to check against: `AUTO_REPOST` clears the bar easily, `MAC` clears the code-byte bar, `AUTO_REARM` is borderline by count but wins on protocol simplicity, `LINK` is the genuinely open question — and `ECHO` never gets built.

---

## 7. Spec Deltas If Adopted (staged, not written)

- §7: `MAC n` row + encoding-note sentence (the `$?B` column).
- §4.2: SQE format becomes normative; cookie hardware-stamping documented.
- New §4.3 "Autonomous Descriptor Behavior": LINK / AUTO_REARM / AUTO_REPOST, each with its completion-visibility guarantee; chain_cancelled added to the status table.
- §6.2: payload-validity contract for AUTO_REPOST rings.
- §10: retire open question 5 partially (chain-fire gives the RBC its first non-instant work — a natural seam for the drain-rate model).
