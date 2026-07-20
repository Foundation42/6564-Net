# sim6564 Measurement Record

Go/no-go data for the MAC & chains sketch (§6 of docs/6564-mac-and-chains-sketch.md).
Regenerate with `sim6564 measure`; append a dated section per feature landing.

## Baseline — pre-MAC, pre-chains (2026-07-16, commit 9aca29b)


| demo | code bytes | instructions | cycles | ctx switches | verified |
|---|---:|---:|---:|---:|---|
| pingpong (0x6564/1024/8) | 479 | 797 | 11028 | 40 | yes |
| supervise (fixed) | 175 | 1458 | 4104 | 0 | yes |
| pipeline (0x6564/1024/16/2) | 1166 | 8479 | 66871 | 317 | yes |
| scatter (0x6564/1024/6) | 518 | 1883 | 13096 | 44 | yes |
| ring (64x100) | 74 | 205055 | 425018 | 12863 | yes |
| **total** | 2412 | 217672 | 520117 | 13264 | yes |

## MAC mechanism landed (2026-07-16)

Mechanism implemented ($?F column, per-context MACTAB at $F80, `bad_macro`
on null vectors, vectors survive SPWN — all tested). Two findings:

**Null cost verified.** With MAC present but unused, the table above
reproduces exactly — the ring holds 66 cycles/pass. The mechanism's
existence costs nothing, as required.

**Corpus analysis says MAC cannot clear its bar here — recording the
arithmetic before any conversion.** The only sequence shared widely enough
to vector is the completion-status extract (`TYA`, 8×`LSR`, `AND #$FF`):
9 occurrences × 11 bytes = 99 bytes, replaceable by 9 one-byte `MAC`s plus
a ~13-byte shared routine ≈ **86 bytes saved, 3.6% of the 2412-byte
corpus** — under the 5% cut line, nowhere near the 20% adopt bar. The
real bulk is `##imm64` staging (9 bytes each), which no call mechanism
touches. Dynamically MAC is strictly negative here: +2 instructions and
+11 cycles per call site (JSR/RTS overhead), which would degrade the ring
headline to ~77 cycles/pass for a 10-byte saving.

**Verdict: deferred, prediction revised.** These programs are straight-line
protocol loops with one instance of each idiom — the corpus a MAC thrives
on (rich subroutine reuse) doesn't exist here yet. Re-measure after the
chain features land (AUTO_REPOST/LINK reshape every serve loop, changing
both numerator and denominator), and after any richer workload joins the
suite. If the picture holds, MAC parks as an optional implementation
feature per the sketch's middle band.

## SQE format + AUTO_REPOST landed (2026-07-16)

| demo | code bytes | instructions | cycles | ctx switches | verified |
|---|---:|---:|---:|---:|---|
| pingpong (0x6564/1024/8) | 560 | 819 | 11067 | 39 | yes |
| supervise (fixed) | 175 | 1458 | 4104 | 0 | yes |
| pipeline (0x6564/1024/16/2) | 1318 | 8946 | 68757 | 345 | yes |
| scatter (0x6564/1024/6) | 556 | 1897 | 13097 | 44 | yes |
| ring (64x100) | 77 | 205120 | 425278 | 12863 | yes |
| **total** | 2686 | 218240 | 522303 | 13291 | yes |

**SQE format (32-byte, op/flags/link, hw cookie stamp): verified no-op.**
Executed instructions identical to baseline; +56 code bytes; the chain
prerequisite is in place at null dynamic cost.

**AUTO_REPOST: flat-to-negative on this corpus — prediction wrong again,
in the other direction.** vs baseline: instructions +0.3%, code bytes
+11% (double-buffer staging + cookie indirection), cycles +0.4%, ring
still 66/pass. The arithmetic: the eliminated `RECV` is one instruction,
and the cap-≥2 requirement forces a `STX` cookie-save plus indirect loads
that cost exactly as much — a serial actor with one outstanding message
was already optimal on a cap-1 ring with a fixed landing address. The
sketch's "biggest single win" assumed the RECV carried bookkeeping weight
it doesn't have on straight-line protocol loops.

**What the numbers don't capture, recorded for the verdict:** both real
deadlocks hit during Phase 3 development (pong's dup-repost wedge, ping's
stale-echo wedge) were precisely missed-repost bugs — the bug class
AUTO_REPOST makes unrepresentable. And the conversion surfaced a third
memory-map overlap (ring demo's widened entry stripe crossing its cell
region at N=200), now regression-tested.

**Recommendation: park as an optional implementation feature** (the
sketch's middle band) — not architectural, but permitted: its value is
robustness-by-construction for receive loops, not instructions saved.
Demos keep it (the code is simpler and self-heals); the spec doesn't
require it. Remaining to measure: AUTO_REARM, LINK.

## AUTO_REARM + LINK landed (2026-07-16) — the sketch's final data

| demo | code bytes | instructions | cycles | ctx switches | verified |
|---|---:|---:|---:|---:|---|
| pingpong (0x6564/1024/8) | 618 | 821 | 11034 | 39 | yes |
| supervise (fixed) | 175 | 1458 | 4104 | 0 | yes |
| pipeline (0x6564/1024/16/2) | 1420 | 8696 | 72034 | 357 | yes |
| scatter (0x6564/1024/6) | 587 | 1442 | 10628 | 35 | yes |
| ring (64x100) | 77 | 205120 | 425278 | 12863 | yes |
| **total** | 2877 | 217537 | 523078 | 13294 | yes |

**AUTO_REARM: adopt-leaning on simplicity, flat on count — as predicted.**
All four timer chains (ping, pipe source/stage, scatter) became stage-once
entries: the per-tick software rearm (2 instructions) is gone, the arm is
one doorbell, and the disarm is one word store that doubles as the
lame-duck/shutdown transition (`LDA #2 / STA !$2480` — op preserved, flag
cleared). Ticks are rare so instruction counts barely move; what improves
is the protocol text: no rearm handler to forget, and a stray final tick
is bounded by construction. The sketch's "borderline by count, wins on
protocol simplicity" prediction — finally one that held.

**LINK: the surprise winner.** Scatter's fan-out became a real chain (ring
head + near-page entries, one doorbell) and the demo dropped from 1897 to
1442 instructions (−24%) and 13097 → 10628 cycles (−19%) — the software
scatter loop's per-worker rewrite executed zero times on the happy path.
Under loss the chain breaks honestly: `chain_cancelled` records post for
every unstarted entry (deterministically tested: ok / reject_capability /
chain_cancelled — stage 3, collect 3), and the straggler timer picks up
the cancelled workers individually. My prediction ("little to grab") was
wrong in the good direction — the corpus had exactly one fan-out shape,
and LINK ate it whole.

**Fixed en route:** local PTT rights-rejects previously bypassed the
completion path — leaving OWNED set forever and, once chains existed,
silently skipping cancellation. They now post through the normal ack
machinery.

### Final scoreboard vs the sketch's §6 predictions

| mechanism | predicted | measured | verdict |
|---|---|---|---|
| MAC | clears code-byte bar | 3.6% max on this corpus | **deferred** (needs richer workloads) |
| AUTO_REPOST | biggest single win | flat count, +11% bytes; kills a real deadlock class | **park as optional** |
| AUTO_REARM | borderline count, simplicity win | exactly that | **adopt-leaning**; spec call is Christian's |
| LINK | genuinely open (I said: little to grab) | −24% instructions where a fan-out exists | **adopt-leaning**, with chain_cancelled as the load-bearing guarantee |
| ECHO | never gets built | never built | **correct by omission** |

Corpus totals vs original baseline: instructions 217,672 → 217,537 (flat),
code 2412 → 2877 (+19%, mostly double-buffer and SQE staging), ring
constant at 66 cycles/pass throughout. The honest summary: the chain
machinery pays for itself exactly where autonomous hardware behavior
replaces *executed software loops* (LINK, AUTO_REARM), and not where it
merely relocates one instruction (AUTO_REPOST) or one call (MAC).

### Adoption decision (2026-07-16)

Christian's call, data in hand: **AUTO_REARM and LINK adopted** into spec
v2.2 (§4.3) — they do real work, and the transistor budget is honest: both
reuse the SEND-accept and descriptor-fetch paths, while everything that
scales lives in software-visible memory ("memory is also transistors —
just shoved somewhere better"). AUTO_REPOST stays a permitted optional
feature; MAC stays deferred; ECHO stays unbuilt. The campaign closes at
five mechanisms prototyped, five measured, two adopted.

## Capstone stress tests (2026-07-16)

Two published actor-machine stress tests, run at full scale (ReleaseFast):

**The Fan-In / Big Brother Test — 10,000 senders, one target.**
Every voice heard exactly once: 10,000/10,000 received, checksum
50,005,000 verified. 610,000 cycles to absorb the flood (61/message,
pop-bound at the sink); 791,742 send attempts with 390,871 no-buffer
rejects answered by per-sender backoff — and **zero CQ overflows**: the
new admission rule (a delivery needs a landing buffer AND a completion
slot; CQ-full is backpressure, §10 Q6) held under maximum contention.
No head-of-line blocking exists to measure: a saturated ring drops and
reject-completes by design.

**The Fork-Join Matrix — 1 → 8×125 = 1,000 → 1,000 relays → 1.**
Forked, relayed, joined: 1,000/1,000, checksum 501,500 verified,
makespan 61,000 cycles across ~2,010 actors. The fork is hierarchical BY
CONSTRUCTION — a destination costs a PTT slot (256/core) and a chain
entry costs 32 near-page bytes (~59 fit) — so fan-out degree is an
architectural constant (data for open question 1). Root→lieutenants is
a LINK chain (7 fires), lieutenant→workers on-die fire-and-forget.

**Found and fixed: AUTO_REPOST's validity window collapsed at
saturation.** The pop-time-immediate grant re-armed the just-consumed
buffer; with the ring drained dry (the flood regime), the next delivery
landed in that buffer between the pop and the software's read —
checksums corrupted at exactly K≳500. The fix is the **deferred grant**:
each pop re-arms the previous pop's buffer, making the contract
unconditional — *a popped payload is valid until the next CQPOP from
that ring*. One bit of hardware state; regression-tested at saturation.
(This slightly shifts the frozen table: total instructions 217,537 →
217,341, cycles 523,078 → 524,034; all demos still verify.)

## The peripheral row landed (2026-07-16, spec v2.3)

Not a mechanism campaign — §7 adds **zero opcodes and zero cycle-model
changes**, so the only measurement it owes is the null-cost rule:

| demo | code bytes | instructions | cycles | ctx switches | verified |
|---|---:|---:|---:|---:|---|
| **total (frozen table, devices attached: none)** | 2877 | 217341 | 524034 | 13285 | yes |

Byte-identical to the post-deferred-grant frozen table above. The
device path costs one hashmap probe per send on the simulator side and
nothing architectural.

New workload data points (not part of the frozen table):

- `hello`: 28 instructions, 1 send — the machine's first words.
- `periph` (seed 0x6564): 2,307 instructions, 47 sends, 43 device
  deliveries, 4 device replies; the program's own RTC arithmetic bills
  the errand at 14,929 cycles, dominated by the glyph-per-datagram hex
  printer (33 console round-trips at ~400 cycles of fabric latency
  each). Console I/O is fabric-latency-bound, as it should be — a
  teletype across a network costs network.

## The IO plane landed (2026-07-16, spec v2.4)

Again no opcodes, again no cycle-model changes — the route byte was
already in the PTT entry (word2 bits 8..16, reserved since v2). Null
cost holds: the frozen table reproduces byte-identically on single-die
machines, with `run()` now literally `runUntil(∞)`.

Multi-die numbers (`sim6564 dies`, ReleaseFast, 16-thread host):

| config | result |
|---|---|
| 16 dies x 200 nodes x 100 laps | 320,000 passes, 24,665,093 cycles (77 cy/pass incl. 1,600 crossings), 0 lost |
| ...threaded vs sequential | **bit-identical** (also at 4x20x5, and with busy rings — test-guarded) |
| busy mode 16x100x10 + 2000 local laps | sequential 1.01 s → threaded 0.27 s (**3.7x**, 666% CPU) |
| ...10x the work | 10.3 s → 2.8 s (**3.7x**) |
| pure global ring, threaded | ≈ sequential wall clock — one token = one busy die at a time; Amdahl's law is about the workload |

Two host-side findings that mattered more than the parallelism itself:

- Thread-per-window spawning burned 3.7x the sequential wall clock
  before the persistent worker pool (16 dies x 12k windows of
  spawn/join). Barriers are cheap; spawns are not.
- The shared GPA was the real bottleneck end to end: switching release
  builds to `std.heap.smp_allocator` took the busy benchmark from
  7.7 s to 1.0 s *sequential* and 2.7 s to 0.27 s threaded. Measure the
  allocator before crediting the architecture.

Correctness catch (worth keeping): the first draft let a die's local
deliveries consult another die's pending map (send-ids are per-die
counters; the origin die wasn't stamped). The plane's own counters
exposed it — 1,510 acks for 40 datagrams. Datagrams now carry src_die,
and foreign acks ride the plane home.

## Thread placement on the 9950X3D (2026-07-16, topology.zig vendored)

Host: Ryzen 9 9950X3D — asymmetric: CCD0 = 96 MB V-cache (cpus 0-7,
16-23), CCD1 = 32 MB, higher clocks (8-15, 24-31). `sim6564 dies …
spread|vcache|freq` pins die threads by L3 domain (topology.zig,
vendored from substr). All five placements produce md5-identical
output — placement is wall-clock only, as the windows guarantee.

Best of 3, ReleaseFast, busy workload:

| config | none | spread | vcache | freq | seq |
|---|---:|---:|---:|---:|---:|
| 16 dies (16 threads) | 0.207 s | 0.164 s | **0.160 s** | 0.167 s | 0.978 s |
| 8 dies (8 threads) | 0.224 s | 0.217 s | 0.190 s | **0.187 s** | 0.992 s |

Findings, in order of size:

1. **Pinning at all is the win (~20-25% over unpinned)** — it stops the
   scheduler migrating die threads across CCDs mid-run. With pinning,
   16 threads reach **6.1x** over sequential (was 3.7x unpinned).
2. **8 threads: one CCD beats two.** Keeping every die on a single CCD
   (either one) beats spreading across both by ~14% — barrier traffic
   stays in one L3 instead of crossing the Infinity Fabric.
3. **V-cache buys nothing here — honestly.** freq edges vcache at 8
   dies: the whole cluster's working set (~1 MB of die RAM plus queues)
   fits in either L3, so clocks win. The X3D asymmetry will only speak
   when per-die footprints outgrow 32 MB; the knob is ready for it.

## The V-cache speaks (2026-07-16, `sim6564 churn`)

The placement table above showed vcache ≈ freq because the whole
cluster fit in either L3. `churn` gives each die a stripe of megabytes
to read-modify-write so placement has something to disagree about —
and the first draft measured **nothing at 64 MB live**: it walked the
stripe at a linear +64 stride, which is a hardware prefetcher's
breakfast. Capacity never got a vote. Lesson kept: **a cache
experiment must defeat the prefetcher before it measures the cache.**
The walk is now a maximal-period Galois LFSR over the line index
(stripe sizes {2,8,16,64} MB — the ones with two-tap maximal
polynomials); verification is unchanged in spirit: every visited line
holds exactly `sweeps`, and line 0 (the LFSR's fixed point) holds 0.

Best of 3, ReleaseFast, 8 dies / 8 threads, LFSR walk:

| live set | spread | vcache | freq | vcache advantage |
|---|---:|---:|---:|---:|
| 16 MB (fits either CCD) | 0.199 s | 0.197 s | 0.203 s | 1.03x — parity |
| 64 MB (fits 96 MB, thrashes 32 MB) | 0.225 s | **0.215 s** | 0.302 s | **1.40x** |
| 128 MB (overflows both) | 0.302 s | 0.278 s | 0.321 s | 1.15x |

The curve is the textbook one: parity while everything fits, a 1.40x
win for the V-cache CCD exactly in the band where 96 MB holds what
32 MB cannot, narrowing again once both overflow to DRAM (96 MB still
catches ~3/4 of a 128 MB set). Placement changes seconds, never bits —
verified counts and cycle totals are identical under every policy.

## Counted shifts landed (2026-07-16, spec v2.5 §8)

`ASL/LSR/ROL/ROR #n` in the $?B column — 2 cycles at any count (a
barrel shifter is constant-time silicon). 186 single-bit shift lines
across 17 programs collapsed to counted forms. The frozen table moves,
for the best reason:

| demo | code bytes | instructions | cycles | ctx switches | verified |
|---|---:|---:|---:|---:|---|
| pingpong (0x6564/1024/8) | 606 | 688 | 11022 | 38 | yes |
| supervise (fixed) | 168 | 1376 | 4043 | 0 | yes |
| pipeline (0x6564/1024/16/2) | 1402 | 7410 | 66703 | 339 | yes |
| scatter (0x6564/1024/6) | 573 | 1318 | 10621 | 35 | yes |
| ring (64x100) | 71 | 160320 | 386884 | 12863 | yes |
| **total** | 2820 | 171112 | 479273 | 13275 | yes |

vs the v2.2 frozen table: instructions 217,341 → 171,112 (**-21%**),
cycles 524,034 → 479,273 (-8.5%), code 2877 → 2820. Benchmarks of
record: Armstrong ring 66 → **60 cy/pass** (200x1000 steady state);
Big Brother 61 → **55 cy/absorbed message** at 10,000 senders. This
table is the new frozen baseline for future null-cost checks.

## WDEX landed (2026-07-16, post-v2.5 handoff item 1)

`WDEX ##n` at $B7 (the $?7 concurrency column, imm64, 3 cycles like
every wide immediate): declare the current burst long by setting its
remaining watchdog budget to `n`. The declaration is supervisor-bounded
— the control block gains a **declaration ceiling** alongside the base
budget (`setWdexCeiling`, privileged, survives SPWN), and `n` above the
ceiling is a fault (`wdex_ceiling`), not a longer leash. At the next
park everything resets to the base budget; a second WDEX in the same
burst replaces the first. The naive "feed the dog" design stays
rejected: a hung loop containing WDEX still dies, because the hang
either re-declares past the ceiling (fault) or exhausts its declared
budget (watchdog trip). Total unyielding time never exceeds what the
supervisor authorized.

Two semantic calls made in implementation, flagged for spec v2.6:

1. **No watchdog armed → WDEX is an architectural no-op.** There is no
   leash to extend, and a joe program full of `bounded` blocks must run
   identically whether or not anyone is supervising it.
2. **`WDEX ##0` cancels the declaration** (back to the base budget,
   measured from burst start) rather than meaning "trip me now".

Null-cost check: `sim6564 measure` reproduces the frozen v2.5 table
byte-identically (2820 / 171,112 / 479,273) — WDEX present but unused
costs nothing. 4 new tests (75 total): declared burst outlives base
budget then declaration dies at the park (fault_addr proves which spin
tripped), over-ceiling faults, replace + cancel semantics, no-watchdog
no-op.

## Tier 0 scalar FP + the extended page (2026-07-16, handoff item 2)

The extended opcode page opens with one prefix byte: **$42 — WDM, the
opcode the 65816 reserved for future expansion when it grew the 6502
and never spent.** One prefix, one page, hard rule: $42 is null on the
extended page itself, so a stacked prefix is an honest `bad_opcode`
fault (test-guarded). No Z80 DD/CB soup, ever. The comptime ISA table
grows a second 256-entry page with the same duplicate detection, and
each FP op sits in its integer analog's row: FADD in ADC's, FSUB in
SBC's, FCMP in CMP's; FMUL/FDIV borrow AND/EOR's.

Tier 0 per the handoff: FP64 in A (the most 6502 shape available), no
new registers, so the volatility question never arises. FADD/FSUB/
FMUL/FDIV/FSQRT/FCMP/FTOI/ITOF, plus FLDS/FSTS (FP32 widens on load,
narrows on store, RNE). IEEE 754, round-to-nearest-even, no FTZ/DAZ,
no fusion. Flag vocabulary: results set Z = numerically zero, N = sign
bit, V = NaN; FCMP speaks CMP's dialect (Z eq, N lt, C ge) with
unordered = V alone. FTOI truncates toward zero (the C-cast
convention), saturates out-of-range and zeroes NaN, V flags both.

Numerics verified bit-exact in Debug AND ReleaseFast: 0.1 + 0.2 =
$3FD3333333333334, the 0.3 residue = $3C90000000000000 exactly,
√2 = $3FF6A09E667F3BCD, 3·(1/3) rounds home to 1.0.

**The proof workload: `sim6564 mandel`.** The Mandelbrot set, 64×22,
z ← z² + c in IEEE doubles on a 6502 descendant, one console line per
row — 291,139 instructions, 1,195,538 cycles, 22 sends, clean halt.
The test asserts every row character-for-character against an
independent host-f64 oracle: 1,408 points × up to 16 iterations, and
one misrounded result anywhere is a visibly wrong character. A picture
as a determinism test. (The Superboard II did this in interpreted
BASIC with 5-digit floats; the lineage now does it correctly rounded.)

Null-cost: frozen v2.5 table reproduces byte-identically with the
extended page present and unused (2820 / 171,112 / 479,273). 81 tests
green (75 → 81: exact-bits, FCMP/FTOI/ITOF vocabulary, FP32 round
trip, prefix discipline, the mandel oracle, extended-page decode).

## joe v1: the language draws first breath (2026-07-16, handoff item 3)

`src/joe.zig` — lex → parse → check → emit, no IR, ~950 lines, output
is .asm text fed to the existing assembler. v1 compiles the pingpong
subset of the sketch: `message`/`actor`/`var`/params, `send`,
`serve`/`case`/`where`/`after`, `if`/`else`, `halt`, `bounded` (lowers
to WDEX), `=`/`+=`/`-=`. Everything deferred parses to an honest
"unsupported in v1" error — including `let`, because park-point
liveness IS handoff item 4 and should not arrive early half-done.

Wire format: word0 low 16 = message tag (declaration order), fields
packed at their own alignment (never straddling a word); ≤ 8 bytes
rides TXR — so `Ping{seq u32}` is still a single register datagram
and the 60-cycle messaging path survives the language. The v1 runtime
ABI is ping.asm's proven wiring verbatim (desc 0/1/2 SQ/CQ/RX, timer
SQ 5, AUTO_REARM black-hole timer, cookie $77 reserved).

**pingpong.joe vs the hand-written protocol** (same fabric, same
seeds, 8 rounds at 25% loss + duplication):

| | code bytes | instructions | cycles |
|---|---:|---:|---:|
| ping.asm + pong.asm (hand) | 606 | 688 | 11,022 |
| pingpong.joe (compiled) | 665 | 1,056 | 11,125 |

A naive tree-walking compiler lands at +10% code, +53% instructions,
+1% wall-clock cycles (the fabric dominates) — and the deep-loss
gauntlet passes: at 73% loss, 12 rounds complete with 121 datagrams
lost and the sequence intact. The end-to-end protocol is compiler
OUTPUT: joe has no syntax for transport acks, so the reliability had
to come from retransmission + sequence discipline, which is the point
of the whole language. Deterministic seed-for-seed (test-guarded).

Null-cost trivially holds (the compiler is a new module; the frozen
table doesn't move). 85 tests green. Next: convert the rest of the
demo corpus, then item 4 — flip the bank-collapse convention in
compiled output and read this same table.

## The system block: deployment is data (2026-07-16)

Christian's call, made before the second demo could demand a second
harness: joe programs should not need a hand-written demo_*.zig each.
What a harness actually does — place actors, wire capabilities, stage
parameters, arm timers — is mechanical once the ABI is fixed, so it
moved into the language as a declarative `system` block:

    system {
        pinger = Pinger(ponger, 8)
        ponger = Ponger(pinger)
    }

Naming another instance as an argument IS the capability wiring: the
loader (src/joe_run.zig) allocates a PTT slot in the sender's core,
aims it at the target's RX ring, and stages the window value as the
addr parameter — §7's "the loader binds it like wiring two actors,"
automated. Placement is one instance per core unless `on N` says
otherwise; instances sharing a core become contexts, each compiled
into its own $1000 block (code, rings, buffers, stack), which is what
made the compiler's Layout parameter necessary and is what the ring
conversion will need at 200 contexts per core (test-guarded: both
pingpong actors forced onto core 0 still complete).

`sim6564 joe <file.joe>` now runs ANY system-bearing source. The
migration is byte-identical: the loader-run pingpong reproduces the
hand-harness numbers exactly (1,056 instructions / 11,125 cycles),
and demo_joe.zig is deleted — the first harness was also the last.
87 tests green.

## ring.joe: the second conversion, and item 4's starting line (2026-07-16)

Armstrong's ring in the language named for him — Head + 7 Nodes, all
`on 0` as banked contexts, the whole deployment eight declarative
lines. The token is still one 8-byte TXR datagram. 100 laps × 8 hops:

| | cy/pass | instr/pass |
|---|---:|---:|
| ring_node.asm (hand-written) | 60 | ~24 |
| ring.joe, v1 naive codegen | **110** | 38.5 |

This number is the point: it is the **pre-registered baseline for
handoff item 4**. The §1 prediction ("ring stays under 70 cy/pass
through joe") is about compiled code AFTER park-point liveness and the
bank collapse; v1's tree-walker reloads every var from the near page,
laps the serve loop once per transport ack just to discard it, and
spills every intermediate. The gap from 110 to <70 is exactly the
work item 4 is for — and now it's measured, not guessed. A regression
guard sits at 130 cy/pass without blessing the current cost.

88 tests green.

## supervise.joe: death is a message, policy is not code (2026-07-16)

The third conversion brings `spawn … restarts R watchdog W` and
`case exit(w, crash(code) | hung | abandoned)` into joe. The sketch's
§2.2 rule — "restarts 3 is policy, not code" — is now literal: the
compiler emits a supervision runtime into the serve loop (match the
obituary to a spawn record, decrement the budget, SPWN or abandon,
classify hung by the watchdog fault code), and the user's cases just
observe. The loader wires each child: a context on the spawner's core,
watchdog + WDEX ceiling, exit link, and a spawn record in the
spawner's near page.

Three design decisions worth the ledger:

1. **Init is idempotent because respawn re-runs it.** Compiled actors
   now self-stage their ring descriptors (head = tail = 0) every life —
   a respawned incarnation starts clean, vars reset "as they should"
   (sketch §1), and the loader got out of the setRing business
   entirely. Migration byte-identical for pingpong/ring.
2. **Timer chains outlive incarnations.** The AUTO_REARM chain is
   address-based, so it keeps ticking across a respawn; an armed-flag
   in the near page (which survives SPWN) stops re-arming from
   doubling the tick rate at every death. `halt ok` disarms; `halt
   err` does not — crashes never clean up, THAT IS WHAT SUPERVISORS
   ARE FOR: the exit runtime stops a dead child's clock only when it
   will stay dead (clean exit or abandoned).
3. **The only hang joe can express is a broken promise.** joe has no
   unbounded loop, so supervise.joe's Sleeper hangs by declaring
   `bounded 40` over a body that costs more — WDEX (handoff item 1)
   makes the lie an ordinary watchdog fault, and `hung` is just its
   fault code. Two items from the same handoff met in the middle.

Run: boss halted with crashes=2, hangs=1, lost=2 — the exact budget
arithmetic (3 Griefer lives, 2 Sleeper lives). The dead lie where they
fell (brk, watchdog), their clocks stopped, and the machine went
quiet in 5,368 cycles — quiescence is the proof the disarm logic
works. 89 tests green; frozen table intact.

## The corpus converges: scatter, pipeline, hello in joe (2026-07-16)

Three more conversions, one new construct.

**scatter.joe** needed nothing new — four workers spelled out where the
sketch has arrays (`for` waits its turn), 16-byte Replies giving the
SEND path its first exercise. Through 25% loss + duplication: got=15,
r0..r3 = 500..503, machine quiescent. The sketch's rule holds in
compiled form: the result is the ack, and idempotent workers make
duplicates harmless — the coordinator has NO dedup and needs none.

**pipeline.joe** brought `quiesce` into the language (statement +
lame-duck case block, sketch §2.3). The compiler emits a second
dispatch loop: entering it kills the timer (AUTO_REARM flag cleared),
serves only the quiesce cases, and consumes everything else in
silence. The poison pill is an ordinary item (val 0) riding the same
stop-and-wait discipline as the data — no Done message needed at all.
sum = 12,615 exact at 25% AND 61% loss; every stage lame-ducks to
parked and the machine goes quiet. Backpressure remains the absence
of an ack; the `case Item(_): say nothing` branch IS the flow control.

**hello.joe** made devices system-block citizens: `tty = Console()` is
wired like any peer (a PTT slot aimed at $FF00), spoken to with
`send tty, "HELLO, WORLD - JOE SPEAKS.\n"` — string literals stage
after the code and ride an ordinary SQE. §7.5 honored end to end: the
Greeter cannot tell it is talking to silicon. One honest note: the
default fabric duplicates, a teletype has no dedup, and the first run
greeted the world twice — `loss 0` on the CLI now means a clean
fabric, and unreliable-fabric device output is a real open question
for the device protocol, not something the loader should paper over.

Corpus scoreboard: pingpong ✓ ring ✓ supervise ✓ scatter ✓ pipeline ✓
hello ✓ — six of the demo suite's protocols now compile from joe.
92 tests green; frozen table intact (2820 / 171,112 / 479,273).
Next: item 4 — park-point liveness and the bank collapse, measured
against ring.joe's 110 cy/pass.

## forkjoin.joe: a thousand-actor tree from ninety lines (2026-07-16)

The last protocol conversion, and the biggest feature drop since joe
drew breath: `for (k, w) in group` and `for i in a..b`, `[]addr` group
parameters (count in the near page, windows in the block's RAM array
area), `var x [N]u64` arrays (ditto), and system-block replication —

    root = Root(ls, 500, 8) on 0
    ls = Lieutenant[8](ws, root, 125)
    ws = Worker[1000](ls)

Group references ALIGN: same size pairs off, larger slices (each
Lieutenant gets its 125 workers as a []addr), smaller shares (each
Worker gets the one lieutenant that owns it). `index` hands a replica
its number. PTT slots deduplicate per (core, target); the black hole
is fixed at slot 255 by the ABI.

**The tree is the reliability architecture.** joe cannot see transport
verdicts, and a thousand-wide fan-in cannot hold a thousand
capabilities anyway (a PTT has 256 slots) — so every hop acks THROUGH
the tree, where both ends hold each other's capabilities: workers
retry Results until acked, lieutenants dedup by index, aggregate, and
retry Done; the root dedups lieutenants. 1,009 instances, end-to-end
reliable, **sum exact at 25% loss + duplication** (501,000, every
lieutenant 62,625), fully quiescent in 1.26M cycles. The suite runs
the same shape at 2×20.

Two findings paid for in debugging, both now structural:

1. **Co-residency of an aggregator with its own flood is starvation.**
   The first 2×20 run packed everything on one core: the lieutenant
   got 1/43rd of the pipeline while 42 senders refilled its ring —
   livelock, n=0 forever. The loader now gives each instance
   declaration its own cores; replicas pack only among themselves.
2. **Nobody says goodbye last.** A root that HALTS on its final Done
   strands any lieutenant whose last ack was rejected in the crush —
   it retries into a corpse forever. The root now `quiesce`s instead,
   lame-ducking re-acks until everyone stops needing to talk. The
   pipeline's termination-as-a-phase lesson, rediscovered at scale.

**bigbrother stays hand-written, honestly.** Its senders retry off
TRANSPORT verdicts — the exact thing joe cannot say, by design. The
flood test lives below the language's floor; fan-in at joe's level is
the tree above. Also deferred with Christian: device sends over a
duplicating fabric want an annotation (default exactly-once framing,
relax by declaration) — the doubled HELLO is recorded, not papered.

Corpus: pingpong, ring, supervise, scatter, pipeline, hello, forkjoin
— **seven of eight protocols compile from joe** (bigbrother
inexpressible by design, documented). 93 tests green; frozen table
intact. Next: item 4, park-point liveness, against ring.joe's 110.

## Amendment 1: the language gets smaller, the promise gets larger (2026-07-18)

Christian's `docs/joe-v1-amendment-1.md` (worked out with Claude Chat,
status: adopted) — *`while` dies, `for` becomes replicated PAR,
`bounded` becomes checkable, `map` stays pure* — implemented the same
day. What the machine had to say about it:

**A1.1, the self-send loop, is physically free of caveats.** `send
self` compiles to a TXR through a loader-staged capability to the
actor's own RX ring, and same-core delivery is ON-CHIP: fixed 4-cycle
latency, no loss roll, never touches the mesh. `crunch.joe` (the new
demo) sums 1..1000 in 20 parked slices of 50: **acc = 500,500 exact,
21 sends, 21 delivered, 0 lost — under the default 25%-loss fabric.**
The construct A1.1 promises ("preemptible, budgeted, fairly scheduled,
observable in the CQ") costs nothing to trust: the loop's messages
cannot be lost, so no retry protocol is smuggled in.

**A1.3 turned out to be almost free to enforce exactly.** The
generator's emitted operand shapes are a closed set, so every line can
be classified back to its addressing mode and charged from the same
ISA table the machine bills from — the computed bound is the
machine's own arithmetic, not an estimate. Constant loops multiply;
group counts and variable ranges flag the burst data-dependent. The
check itself is the amendment's table, verbatim: required iff over
budget or unseeable, rejected if understated, rejected if gratuitous
(including any `bounded` in an actor nobody watches — "nobody is
counting").

**The Sleeper's lie had to move, and where it moved is the finding.**
The old hang — `bounded 40` over five adds the compiler can now sum —
is a compile error today. The only joe-expressible hang left is a
declaration whose *data* is dishonest: `bounded 64` over `for i in
0..spin` where spin is a variable. Arithmetic lies die at compile
time; data lies die at the watchdog; there is no third place to lie.
supervise.joe's observable behavior is unchanged (crashes=2 hangs=1
lost=2), which is the point — the amendment removed a way to write
the bug without removing the demo of catching it.

A1.2 required no work (joe's `for` was born in the amendment's shape)
and A1.4/A1.5 ride with Tier 1 (item 5) — vector syntax without a
vector unit would be front-running silicon.

101 tests green (8 new: 6 checker rejections/acceptances, `while`'s
targeted error, crunch end-to-end). Frozen table intact; ring.joe
still 110 cy/pass, still item 4's starting line.

## Item 4: the bank collapse, measured — the convention beats the heroics (2026-07-18)

The §1 decision — registers become one shared set, volatile across
parks; a context is near page + run-queue entry + control block — was
pre-registered with predictions on the record: *ring stays under 70
cy/pass; the spill tax is smaller than feared.* The experiment ran as
specified: through joe, no hand-conversion heroics, the compiler's
park-point liveness as the register allocator.

**ring.joe: 110 → 55.26 cy/pass. The hand-written ring pays 60.**

The compiled ring now beats the hand assembly it was chasing. The whole
Node serve loop is 13 instructions: a 35-cycle deliver burst and a
12-cycle ack burst. The prediction said the collapse convention would
cost little; it turned out to cost *less than nothing*, because the
convention forced discipline the hand ring never had:

- **The fused deliver test.** word0's low 16 bits are status<<8|tag, so
  `AND ##$FFFF / CMP #3` accepts exactly a clean delivery in ONE
  compare — acks, exits, timer ticks and empty pops all fail the same
  test. The old dispatcher's separate status check, tag check, and
  empty-pop branch are gone.
- **Registers are free within a burst.** word0 rides in Y only when an
  exit or timer path will want it; the message tag is compared in A
  down a 2-instruction-per-miss ladder; a sole unguarded case skips
  the tag test entirely (the wire is closed — every sender compiles
  from the same source, one pattern means every delivery matches).
- **Sends compose in A.** The near-page `_acc` is touched only between
  field evaluations of multi-field messages; single-field messages
  never touch it. Masks dedup: a literal masks at compile time, a
  bound field was masked by its own load.
- **Direct operands.** `x += 1` is INC; compares and arithmetic with a
  literal or scalar-slot right side address it directly; `== 0` costs
  nothing (every evaluation ends setting Z).
- **The stack is cold.** Expression temporaries are static near-page
  slots (depth known at compile time, four deep, refused honestly
  beyond). There is not one push in the compiled corpus — so even SP
  owes the parks nothing, exactly as §1 demands.

The corpus, before → after (same seeds, same loss):

| program | naive v1 | item 4 | hand |
|---|---|---|---|
| ring (cy/pass) | 110 | **55.26** | 60 |
| pingpong (cy / instr) | 11,125 / 1,056 | **11,078 / 745** | 11,022 / 688 |
| crunch (cy) | 75,293 | **41,091** | — |
| forkjoin, 1,009 actors (cy) | 1,260,000 | **955,190** | — |
| supervise (cy) | 5,367 | 5,366 | — |

pingpong sits at +0.5% cycles and +8% instructions against the hand
protocol — the makespan is latency-dominated, and the code-side gap
closed from +53% instructions to +8%. forkjoin's full-scale makespan
dropped 24% and still joins to the exact sum at 25% loss.

**The proof is scorched earth, not inspection.** The machine grew
`scorch_parks`: at every real park (LSTN that parks, YLD) it poisons
A, X, Y, SP and P with $DEAD6564DEAD6564 and sets every flag — the
maximally hostile implementation the collapsed convention permits.
The entire joe corpus runs **cycle-identical** under it (states, vars,
console bytes, cycle counts — asserted in the suite; also from the
CLI: `sim6564 joe file.joe seed loss scorch`). Nothing compiled ever
trusted the banked file.

**Verdict for v2.6 (Christian's call to make, numbers now on the
table):** the collapse pays. Registers were never where state lived —
the 6502 knew this; variables live in the near page and registers are
burst-scratch. What silicon buys back: the per-context register file
deleted, SPWN's register reset deleted, the zero-cycle switch now
literally zero mechanism. What it costs: the architected control-block
stripe (incarnation, exit link, watchdog budgets) with hardware write
protection against the owning context — the one new mechanism, spec
work for the v2.6 draft (item 8).

103 tests green (scorch invariance across seven programs, stack-free
corpus assertion, ring guard moved 130 → 70 = the prediction, not the
achievement). Frozen asm table untouched — the hand corpus never
changed, which is the point: the convention was measured, not the
programmer.

## Amendment 2, phase one: bytes are honest, and #13 speaks (2026-07-18)

Christian's `docs/joe-v1-amendment-2.md` (struple as joe's tuple
encoding; views as indices; the store as a §7 device) began landing the
day it arrived — before item 5, by its own logic: the client surface is
pure scalar work, the conformance oracle already existed with twelve
byte-identical implementations behind it, and scorch was still warm.

**The joe/6564 implementation is struple's thirteenth**, split exactly
as the machine splits: `src/struple.zig` is the host half (the subset
packer joe's compiler pre-packs constants with, the reader the tests
oracle against), and the code joe EMITS is the machine half. Both are
driven by the vendored corpus (`src/struple_vectors.json`, verbatim):

- Host half: every subset vector byte-identical in both directions;
  every vector — big ints, decimal, map, set included — skips totally.
- Machine half, under scorch, per A2.7: **the full corpus walks on the
  simulator** — `.count()` compiles to the total element skip (all 18
  type codes, framed scans, complemented big-int length prefixes,
  decimal sign/exponent/digit structure), and every vector lands the
  host reader's exact element count at the exact final byte. The int
  encoder (`pack key, (v)`) reproduces every utterable corpus vector
  byte-for-byte — type code $20+n, big-endian magnitude, peeled
  MSB-first by counted shifts because variable shift counts do not
  exist on this machine.

**The surface**: `var key buf [64]u8` (near-page slab + length slot),
`pack key, ("users", id, "profile")` (constants pre-pack at compile
time into immediate word stores; a variable u64 appends at runtime
through unaligned near_x stores against the slab's 8-byte slack),
`key bytes` message fields (length byte + payload, 8-aligned, filling
the envelope; one per message, last, forwardable whole), and A2.4's
prize: `case Get(g) where g.key is ("users", ?id, ..rest)` — constant
prefixes fuse into 8-byte word compares against pre-packed bytes, `?x`
decodes and binds one element (a non-subset element fails the match,
honestly, it does not fault), `..rest` binds a view, and no rest means
end-of-stream. Dispatch on a structured key costs word compares.
`keys.joe` proves it end to end: three packed keys through a router,
one bound with a rest view (len 9, the encoded "profile"), one exact,
one falling through both patterns to the wildcard — scorched and not.

**A finding worth its ledger line: the on-chip self-send outruns the
park.** The first keys.joe machine-gunned three sends from one burst
and starved its co-resident router into rejecting the third — because
at 4-cycle on-chip latency the A1.1 self-send loop's next message has
ALWAYS already landed when LSTN runs, so "one park per slice" is one
CHECK per slice, and the burst never yields the core. Three lessons,
two old and one new: the loader's each-declaration-owns-its-cores rule
exists precisely for this (I had overridden it with `on 0` — don't);
flow control without transport verdicts is the corpus's own
result-is-the-ack pattern (keys.joe now stop-and-waits, robust at any
placement on any seed); and serve-loop fairness on a shared core
(should the dispatcher YLD between bursts?) is a genuine design
question for Christian — recorded, not decided.

Deferred to A2-ii with the store (item 6): region-backed bufs, the
store device itself (`~/dev/substr` is the polyfill behind the §7.5
contract), sized `bytes[N]` fields (Put/Scan want two per message),
f64/uuid/timestamp machine-side encode, view navigation beyond
`.count()`, and D1's key-as-location — remembered, non-normative.

109 tests. Frozen table intact; ring still 55.

## Contended LSTN: hot delivery is a privilege of an idle core (2026-07-18)

Christian's verdict on the self-send finding, priced as prescribed —
and first, his diagnostic question answered from the source: **the
burst budget runs on the dispatch clock** (machine.zig: `burst_start`
is set only in `dispatch()`, and the trip check reads `clock −
burst_start`). A never-parking loop is therefore ONE accumulating
burst: a *watchdogged* hot loop does eventually trip — the belt
already existed. keys.joe's asker ran happily because system-block
instances carry no watchdog: the starved neighbor was invisible
exactly and only for the unwatchdogged. That is the hole the rule
closes — and it closes it in the machine, not in joe, because joe
does not know what a core is. Fairness is not the program's job.

**The rule, one branch:** an LSTN that finds its ring non-empty still
rotates when another live context on the core is runnable — requeued
past the LSTN, registers volatile exactly as at any park (scorch
poisons the rotation too). The check is a pure function of run-queue
state the scheduler already holds, so bit-exact replay is untouched.

**The price, measured:**

| benchmark | rule off | rule on |
|---|---|---|
| ring.joe (8 co-resident, cy) | 44,208 | **44,208** |
| hand ring (cy/pass) | 60 | **60** |
| hand pingpong (cy) | 11,022 | **11,022** |
| crunch.joe (self-send loop, idle core, cy) | 41,091 | **41,091** |
| machine-gun keys (co-resident) | 1+ rejects, 2/3 keys | **0 rejects, 3/3** |

Zero cycles, everywhere — and the ring rows are not vacuous: the
rotation count there is zero because at steady state the ring never
*enters* the hot path (the 4-cycle on-chip delivery exceeds the
2-cycle loop-back to LSTN, so every node genuinely parks). The rule
fires only where a burst is long enough for its own next message to
beat it back to LSTN — pack work, compute slices — and exactly there
a starving neighbor exists to deserve the rotation. Item 4's collapse
made the switch zero mechanism, so the fairness costs one honest
branch: **the collapse funds the fairness.**

This also repairs A1.1's falsified clause with a better one: not
"every iteration parks" but "every iteration parks *when anyone needs
the core*" — the hot path survives precisely where it is harmless.

Residual, as directed (belt to the braces): since the budget clock is
dispatch-based, the belt already accumulates across unparked bursts
for watchdogged actors; whether an *unwatchdogged* context should
also face some ceiling on an unparked run is left as a v2.6 spec
question — with contended LSTN in place, such a run can only occur on
an idle core, where nobody is harmed by it.

Suite: 111 tests (the starvation is now a regression test in both
directions). Default: on. v2.6 records "contended LSTN parks" with
this table as its pricing.

## store.joe: the substrate's shape, polyfilled in joe itself (2026-07-18)

Christian's call: at this stage the store polyfill should be JOE, not
the host engine behind a device coordinate — §7.5 discharged in the
strongest available way. "Any device contract must be implementable by
an ordinary actor" is not an argument anymore; it is a program:
`store.joe` serves Put/Get/Del with canonical struple keys from four
buf slots and a bitmask, and the radix engine, a dedicated node, or
real silicon can stand behind the same messages later with no client
the wiser.

Two small byte capabilities made it writable, both A2-shaped:

- **`copy dst, src`** — bytes into a buf from another buf or the bound
  message's bytes field. Whole-word copies; capacity checked (BRK on
  overflow, the pack_overflow law).
- **Byte equality** — `k0 == p.key` in any condition. Lengths first,
  then whole words, then the tail word under a mask from a near-page
  table (the ISA has no variable shifts, so `2^(8k)−1` is a lookup,
  staged once per life). Compare joins `where`/`if` through the same
  branch machinery as everything else.

The client walks a nine-step script, one request in flight (the reply
is the ack), sequenced through an A1.1 self-send: Put ("rocci","hs")
4242, Put ("users",1,"name") 111, overwrite to 4343, Get → **4343**,
Get → **111**, Get ("ghost",9) → Miss, Del, Get-the-deleted → Miss.
misses=2, used=1, quiescent, 24/24 delivered — scorched and not.

**A bug worth its whole ledger line: the store was the first actor to
outgrow the block.** 2,216 bytes of client against a 2KB code region
(`data_off $800`) meant the CQ ring silently overwrote the code tail,
and the machine faulted `bad_macro` executing its own completion queue
at a mid-instruction address. The failure was honest (a fault, not
corruption-and-continue) but the overlap was silent at load time — the
recurring RAM-layout hazard, fourth incident. The block is now 16KB
(8KB code + 8KB data), and the loader REFUSES oversized code instead
of overlapping it. Cost of the growth: zero cycles everywhere (ring
still 44,208 to the cycle).

Deferred, still honest: byte values (sized bytes[N] fields), Scan and
ordered iteration (memcmp ORDER, not just equality — wants the range
machinery), multi-client reply routing (the `.from` question), store
capacity beyond four (buf arrays or regions — A2-ii). Christian's
rocci-bird sketch (docs/rocci-bird-joe.md) now sits in the docs as the
north star for items 5/6: display/pad/APU devices, granted regions,
SoA vectors — and its high score lives at `("rocci", "hs")`, which
this store already serves.

112 tests. joe now: 10 programs, 3 of them shipped today.

## Item 5: Tier 1 vectors — the extended $?7 column, spent whole (2026-07-18)

The order of work said vectors only after the collapse, so the
volatility convention would exist before vector state did. It paid
exactly as designed: **V0–V7 × 512-bit is ONE shared file per core** —
never banked, never saved by hardware, poisoned by scorch at every
park like everything else. The register story didn't grow a special
case; the wide registers simply joined the convention.

Fifteen opcodes on the extended page's `$?7` column (the base page
spent its `$?7` column on I/O and concurrency; the extended page
spends its on the vector unit): `VLD`/`VST` (64 bytes at the address
in X — zero new addressing modes), `VBCA` (broadcast A), lanewise
f64 (`VFADD/VFSUB/VFMUL/VFDIV`, cycle-priced as the scalar ops: eight
lanes are parallel silicon, not eight passes), lanewise u64
(`VADD/VAND/VORA/VEOR`), three reductions, and `VPERM` with its lane
indices riding in A, one byte each. Two-register forms pack
`(d << 3) | s` into the one desc byte — `VFADD 0, 1` in the source.

**Reduction order is part of the contract**, per the determinism bar's
"including reduction order": `VRADD` is the pairwise tree
`((l0+l1)+(l2+l3))+((l4+l5)+(l6+l7))`, one shape, always — and the
suite proves the shape by *distinction*: lanes `[1e16, 1×7]` yield
1e16+6 through the tree but tie-to-even into exactly 1e16 through a
sequential fold, and the machine must produce the tree's bits.
`VRMAX/VRMIN` fold sequentially with lane-0 tie bias; any NaN wins as
the one canonical NaN.

**The workload: a 256-element f64 dot product.**

| | cycles | result |
|---|---|---|
| scalar (Tier 0 loop) | 12,830 | bit-exact vs host sequential fold |
| vector (VLD/VFMUL/VFADD + VRADD) | **2,017** | bit-exact vs host lane-mirror + tree |

**6.4× — and the two results differ in bits, honestly**, because they
are different spec'd summation orders; they agree in value to 1e-9.
The machine never pretends two arithmetics are one.

V volatility is proven the house way: fill V0, YLD, store — under
scorch every lane comes back as the poison pattern. The convention is
the contract, not the luck of an idle core.

Open item 8's V-count question, first data: 8×512-bit served the dot
at 6.4× and maps onto mandel's row tiles and rocci-bird's SoA pipes
(8 f64 lanes = one pipe attribute across the whole on-screen set).
f32 16-lane forms are deferred until a workload demands them — size
to the workloads, not more. The joe A1.4 surface (vector literals,
element-wise operators, `.reduce(+)`) needs f64 in joe's type grammar
first — it rides next, with the same lowering discipline.

116 tests. Null-cost holds by construction: nothing that doesn't
speak `$42 $?7` moved a cycle; frozen table intact; ring still 55.

## A1.4: the vector package lands in joe (2026-07-18)

SIMD is a data type with operators, not a loop — and now joe says so.
The prerequisite was f64 entering the type grammar: float literals
(with e-notation), `f64` vars/params/message fields, `+ - * /` through
the Tier 0 ops, comparisons through FCMP's flag conventions (every
NaN comparison false except `!=`, exactly IEEE), and the explicit
conversions `f64(e)`/`int(e)` (ITOF/FTOI — no silent coercion, though
integer LITERALS promote in float context, so `v * 2` means what it
says). Integer × and ÷ remain honestly absent: the machine has no MUL,
and joe won't pretend ("shift-add, or take it to f64").

**`vec` is eight f64 lanes in a 64-byte near-page slab.** Expressions
ride the V file and every statement stores back — so the Tier 1
volatility convention holds *by construction*: there is no syntax that
keeps wide state live across a park. Element-wise `+ - * /` with
scalar broadcast on either side, `.reduce(+ | max | min)` through the
spec-fixed tree, `.permute([…])` with constant indices folded into
the A-format mask at compile time. Deferred with reasons attached:
compare→mask rides with VSEL and its first workload; `map` waits for
functions to exist; gather/scatter are region-typed (item 6).

`vecmath.joe`: 659 bytes, 462 cycles, and every result bit-exact
against a host mirror — the tree sum of `v*2+1` over lanes 1..8
(80.0), max 17, min 3, a permute-broadcast proven through its sum,
1/3 to the bit, and one lovely footnote: `int((1.0/3.0) * 300.0)` is
**100**, not 99 — the product rounds to exactly 100.0 under RNE
before FTOI ever sees it, and the machine and the mirror agree on
that bit for bit. Determinism includes the surprises.

Also fixed in passing: the A1.3 cost accountant now bills from BOTH
opcode pages — FP and vector instructions were invisible to the
bound checker before this (joe had never emitted them; now it does,
and a watchdogged actor's float handlers are charged honestly).

117 tests. The A1.4 grammar is complete except where the machine
itself isn't yet (masks, map, gather) — each deferral named, none
silent.

## Item 6, machine half: registered regions + the matmul accelerator (2026-07-18)

§4's composition claim held to the letter — regions needed almost
nothing new, because **the descriptor table is the region table**: a
region is a descriptor with the REGION flag (word0 base, word2 length,
word3 token), living in the near page like every ring the actor owns.
Grant-on-submit sets an OWNED flag in that descriptor; the completion
is the release fence (OWNED clears before the record lands); and
revocation is the actor zeroing its own token word — no opcode, no
syscall, one store.

**The matmul accelerator, in two implementations behind one contract**
(request: region slot, token, M|K|N ≤ 32, three in-region offsets;
completion: a delivery to the requester's RX ring). The in-proc "TPU"
DMAs the granted region; the fabric-remote polyfill pulls and pushes
it through the network window in 64-byte chunks with the same token —
the future §6.4 reserved the PTT write right for, now real. Both
declare `deterministic`: C[i,j] = Σ_k A[i,k]·B[k,j], k ascending, IEEE
RNE — the reduction order is in the contract, so the two silicons
agree TO THE BIT, and the suite proves it with the same driver program
for both: the test changes one PTT binding and nothing else. §7.5 in
one line of wiring. The only observable differences: window-chunk
traffic (stats.accel_pulls) and the wall clock — which a parked core
doesn't pay.

**The failure modes, exercised where the deferred-grant lesson said to
look:**

- *Revocation between grant and completion*: the requester waits for
  the transport ack (the ack IS the acceptance), then kills the token
  mid-flight. The late DMA re-reads the LIVE descriptor — the
  deferred-read discipline — and reject-completes: C untouched, OWNED
  still fenced clear, the record still arrives. Revoke a wedged
  accelerator and its late DMA cannot scribble on reclaimed memory.
- *Saturation*: two asks at a depth-one unit — the second is
  reject-completed at the sender (backpressure as a transport
  verdict), the first completes bit-exact. Saturation is backpressure,
  never corruption, same law as bigbrother's flood.

Two test-shape lessons paid for and recorded: the core clock counts
executed cycles, so a parked wait is free and "slower silicon" is not
visible in core.clock; and revoking before the grant arrives tests
request rejection, not late-DMA fencing — the ack-then-revoke ordering
is the honest window, and the remote implementation's longer flight is
what holds it open.

Deferred to item 6b (the joe surface): `region` declarations and
`grant` with the type-state — a granted region inaccessible by type
until the completion case rebinds it, §6.2 promoted to compile time —
plus region-backed bufs for A2-ii's store hardware and rocci-bird's
display grants.

120 tests. Null-cost: nothing that doesn't speak to $FF05/$FF06 moved
a cycle; frozen table intact; ring still 55.

## Item 6b: joe grants — §6.2 promoted to compile time (2026-07-18)

The sketch's §2.5 example now compiles and runs. `var frame region
[96]f64` is a RAM array wearing a descriptor (slot 8 up, staged at
init beside the rings, token = the ABI token); `send tpu, Mul{grant
frame, …}` stages the descriptor slot and the LIVE token as two wire
words and flips the compile-time type-state; the accel's completion —
the architected $6772 tag, far above any program's tag space, status
riding above it, slot in word1 — routes to `case done(frame)` /
`case failed(frame)`, which rebind. The contract gained one reserved
leading word so silicon and joe agree on framing without the device
ever knowing a program's message table.

**The type-state is v1-conservative and honest**: a granted-anywhere
region is accessible in a handler only BEFORE that handler's own
grant, and inside its done/failed cases; every other handler must
keep its hands off, because it may run while the region is
hardware-owned. Both violations are compile errors with §6.2 in the
message, and both are in the suite as negative tests.

`matmul.joe`: fills A and B in-region, grants, parks; done rebinds
and reads C's corners — checksum 379.0 (C[0,0]=50 + C[3,3]=329,
hand-checked), **bit-identical against both silicons under scorch**,
where the remote run differs only in window traffic. The test swaps
`Matmul()` for `MatmulRemote()` — one name in the system block — and
nothing else. The loader knows both as device-table citizens.

Also fixed en route: wire fields wider than 8 bytes align to 8, not
to their own size (the grant field had drifted one word off the
silicon contract), and the machine rejects a grant of an
already-owned region (backpressure, same as busy).

122 tests. Item 6 closes whole: regions, two accelerators, revocation,
saturation, and the language's hands tied exactly where the hardware
owns the memory. Next: item 7, the MAC re-trial on a compiled corpus
that finally has real subroutine reuse — then the v2.6 draft, with
every verdict of this campaign in its basket.

## Item 7: the MAC re-trial — reuse arrived, and MAC was waiting (2026-07-18)

The original trial deferred MAC with data: hand-written code had no
reuse worth a vector table. The deferral said re-measure when compiled
code exists — and the compiled corpus now writes the same comparator
twelve times into one actor. The re-trial, on store.joe under scorch:

| | code | cycles | MAC calls |
|---|---|---|---|
| inline (today's default) | 3,429 B | 10,612 | 0 |
| `use_mac` | **2,353 B (−31.4%)** | 10,935 (+3.0%) | 12 |

The mechanism: byte-equality sites whose shape matches — a buf against
a bytes field at a known offset — collapse to a four-instruction call
(stage the buf's slot, `MAC n`, branch on the returned verdict) through
one comparator routine per distinct field offset, each in its own
MACTAB slot (store needs two: Put's key rides at +16, Get/Del's at
+8 — the first single-shape attempt caught only a third of the sites,
and the census said so). Sites that don't fit any shape inline exactly
as before; programs without reuse pay nothing (null-cost held at flag
off, to the cycle).

**The collapse's tax, measured**: MAC is JSR-shaped and SP is
park-volatile, so every burst re-establishes the stack — two
instructions after each LSTN. That plus the call/return linkage is the
whole +3.0%. Item 4 removed the stack; item 7 rents it back per burst,
only where a program opted in, and scorch proves the linkage never
leans on anything a park destroys.

**Verdict shape (Christian's call, numbers on the table)**: MAC pays
where reuse lives — comparator-heavy, pattern-heavy actors — at a
cycle cost that stays invisible in latency-dominated protocols. As a
per-deployment flag it is honest today; as a default it should wait
for the store hardware phase, where the byte-walkers multiply. The
per-context MACTAB means no cross-actor sharing: the bigger prize
(one comparator for the whole core) is a shared-code-pages question
for v2.6's table, noted and not smuggled.

123 tests. The §7 order of work is now COMPLETE through item 7;
item 8 — the v2.6 draft — is all that remains, and its basket is full.

## Item 8: the v2.6 draft — transcription, not design (2026-07-18)

The capstone, and Christian named its character before it was written:
the basket held no guesses, so the spec draft was the transcription of
evidence. `docs/6564-net-architecture-v2.6.md` (v2.5 archived):

- §2.2 rewritten around the collapse — "41 bytes, and none of it is
  saved"; context = near page + run-queue entry + control block; the
  clobber set enumerated; ring 60 hand / 55.26 compiled; scorch as
  the mechanical proof obligation.
- §3.3 the control block (write-protected: an actor must not edit its
  own leash); §3.4 the shared, park-volatile V file.
- §5.2 contended LSTN normative, with its rationale and its zero-price
  claim; §5.4 gains WDEX with the dispatch-clock semantics and the
  checked-`bounded` language note.
- §6.2 widened to registered regions: descriptor-table-as-region-table,
  grant-on-submit, completion-as-fence, revoke-by-one-store with
  late-DMA reject, remote pulls legitimized, the $6772 convention,
  saturation-is-backpressure.
- §7.4 gains the matmul row; §7.5 gains the numeric addendum (the
  `deterministic` flag, set/clear semantics); new §7.6 accelerator
  actors.
- §8.1 the extended page ($42, non-stacking) + both FP tiers with
  reduction-order-in-the-contract; §8.2 MAC adopted as optional with
  its −31.4%/+3.0% numbers; WDEX joins the §8 table; SPWN's row
  reflects that there are no registers left to reset.
- §10 gains the joe campaign summary; §11 gains five new questions
  (capability transfer as three-costumes-one-mechanism, exactly-once
  framing, shared code pages, the unwatchdogged-burst ceiling, vector
  width) — every deferral this campaign filed, none smuggled.
- The closing line no longer promises: "Nothing in this revision was
  designed at the desk. It was all transcribed from the machine."

123 tests; every measured number in the draft has a guard in the
suite. THE POST-v2.5 HANDOFF IS COMPLETE — all eight items. The
frontier beyond the spec: store hardware behind store.joe's proven
contract, rocci-bird's device row (display/pad/APU, PresentDone as
the frame clock), sized bytes fields, buf arrays, VSEL-and-masks,
and D1's key-as-location — each waiting on the table, honestly.

## The harness retirement — contract directives and the generic .asm runner (2026-07-19)

The Sunday tidy-up that became a campaign: every hand-written program's
"Harness contract" comment was already a deployment spec written for
humans, and fourteen demo_*.zig files were humans executing it. Now the
contract is directives (`.actor`/`.ring`/`.timer`/`.stage`/`.reserve`/
`.var`/`.use`/`.system` — src/asm.zig, metadata only, not one emitted
byte changes), the `.system` block is joe's own grammar read by joe's
own planner, and one loader (src/asm_run.zig) executes it:
`sim6564 run <file.asm|file.joe>`. Ten harnesses retired (~2,400
lines); dies/net/churn/web stay as infrastructure. Canon moved into
integration tests against generic-runner Outcomes, verified program by
program BEFORE its harness died:

| program | verdict vs its harness |
|---|---|
| ping/pong | **bit-identical** — 11,022 cy, final 8, retrans 3; also at 0xBEEF/2048 |
| scatter | **bit-identical** — 10,623 cy, Σ(i+3)²=492; both seeds |
| supervise | **bit-identical** — 4,043 cy, 12/20/12/9 items, 5 restarts, brk + watchdog |
| pipeline | **bit-identical at 3 shapes** — 66,703 / 83,076 / 29,376 cy, fabric stats equal |
| ring | **cycle-identical** — 50,044 cy at 8×100; 60.0/pass marginal; 60/pass at 200×1000 |
| bigbrother | **55 cy/message exactly** at 1k and 10k; 550,000 cy total, checksums exact |
| forkjoin | **exact canon** — 1000/1000, checksum 501,500, 55,000-cycle makespan, 2,010 instances |
| mandel | all 22 rows **character-for-character**, same instruction count |
| periph | transcript-identical, elapsed 14,759 by the machine's own RTC |
| hello, http_get | output-identical; web instruction-exact per paired run (the old 784 was stale — example.com changed) |

Vocabulary lessons, each priced by a failure or a conversion: `.reserve`
(three independent loader-over-scratch collisions), `reply` + per-device
tokens (periph; the RTC answers to token 0), `rx=N` (a pipeline stage is
targeted on two rings), `sup @ cell watchdog=N` (supervision staged as
data), cap[] group alignment incl. singleton-as-shared-1-group
(forkjoin's one actor, two partner kinds), `.timer period=N` (a measured
horizon without a phantom black hole), and the send-timeout epilogue
(2000, the horizon the corpus was measured against). Two programs
changed code — flood_sender and fj_pass now stage their own SQEs from
their near-page descriptors, because pre-staged SQEs are inexpressible
for replicas and self-staging is what joe's compiled init already does;
their absorption/makespan clocks are unchanged and exact. One honest
regression of scope: scatter's parametric worker count fixed at the
contract's 8 (the staged fan-out chain is deployment, and deployment
now lives in the file). README's forkjoin makespan corrected 61k → the
measured 55,000. Guide: docs/asm-guide.md.

## Amendment 3 — the device conversation (2026-07-19)

Christian's read-through adopted the draft same-day; implemented in one
run. The tidy-up was the survey party and this is the road: mandel,
periph and http had no joe voice, and rocci-bird had been writing half
this surface as if it existed.

| piece | shipped |
|---|---|
| A3.1 `let` | burst-local binding, item 4's semantics made law: dies at its block's end (every v1 park is a block boundary), typed from its initializer, no shadowing, no reassignment. Corpus recompiles unchanged. |
| A3.2 raw bytes | `const`, byte indexing, `clear`/`append`, `send tty, b`. **pack speaks struple to actors; append speaks raw to devices** — two dialects, one boundary. |
| A3.3 echoed tags | §7.3 addendum across the tower: uniform ask framing (tag, window, args), replies echo the tag with data at +8. joe's `message Ask {…} -> Reply {…}` pairing; `-> _` tells. periph.asm + http_get.asm/demo_web reframed and re-verified. |
| A3.4 records | `struct` as named near-page offsets; scalars only. |
| A3.5 device row | Entropy/Rtc/Block/Net nameable in a joe `system`, per-device tokens, reply windows aimed back at the asker. |

Programs: **mandel.joe** — 22 rows character-for-character against
mandel.asm and the host oracle (three implementations, one set of
bits). **periph.joe** — entropy stream identical to the assembly
errand, disk round-trip verified, own cycle bill in hex. **http.joe** —
868 bytes of Example Domain over a real socket, headers + chunked body
+ terminating chunk, the §7.5 story told from the language.

Rules the machine handed back, each priced by a program that failed
without it:

- **The reply window is the request for a reply.** periph.joe could not
  order a write before its read-back — a driver that cannot see
  transport verdicts has no other sequencing point. A device that
  answers now answers writes too when a return address is present, and
  stays silent when the window word is zero, which is what periph.asm
  stages: the assembly contract never moved.
- **Never hand hardware a pointer into hardware's own buffer.**
  Forwarding a reply payload straight from AUTO_REPOST space dropped
  chunks; the compiler now stages the copy, and overflowing the staging
  area is a compile error (the RAM-overlap lesson, charged early).
- **The fabric already counted the bytes** — `payload.len` reads the
  completion's count field, so a raw reply needs no in-band framing.
- One drift repaired: joe had two string-escape decoders and only one
  knew `\n`; neither knew `\r`, so every CRLF was "rn" and cloudflare
  answered 400 Bad Request. One decoder now.

## Amendment 4 — rights on capabilities (2026-07-19)

Christian's sketch, priced. The rights word splits into **dialect** (what
an endpoint IS — equality-checked, not attenuable) and **verbs** (what a
holder MAY DO — subset-checked, attenuable). `any` is unset, not top: its
checks are skipped rather than satisfied, so replacing it is not
attenuation, and a derived capability may never carry it.

**Movement 1 — the dialect check.** Claim in the SQE's reserved hint
word, compared against the endpoint at accept, one step after the rights
test. TXR claims `msg` structurally (you cannot print a register), so the
hottest path encodes nothing.

| pre-registered claim | outcome |
|---|---|
| null cost | **byte-identical frozen table**: 2820 B / 171,532 instr / 479,275 cy / 13,281 switches |
| rejected programs | 3 compile errors: msg→raw sink, raw→actor, msg→ask device |
| the bypass test | hand-written `.asm` lying about its claim: **rejected by the RBC**, console unheard |

**Movement 2 — succession.** `SqOp.grant`: hardware picks the grantee's
slot, mints a fresh token, surrenders the grantor's copy, narrows verbs
to the granted subset, and delivers a grant record carrying provenance
(core, context, incarnation, source slot). Three refusals, one rule —
what you do not hold, you cannot pass on. Frozen tables unmoved again.

**The finding.** Movement 1's tripwire (if transfer wants to modify a
dialect, the boundary is wrong) stayed silent — because a region carries
no dialect at all. Dialect is an endpoint property; a span of memory is
not an endpoint. **Verbs are universal; dialect belongs to things you
send to.** The asymmetry was not designed, it fell out of building both.

Also this pass: §2.3 promoted from observation to principle — *every
static check is the early copy of a dynamic one; a compiler never
extends trust, it only moves a reject earlier in time* — with the
diagnostic corollary that a static check lacking a runtime twin is a
smell (it would have caught A3.6's gap by inspection). And §6.3's
one-shot timer discipline: a liveness-bearing timer must be AUTO_REARM,
because a dropped one-shot timeout is the eternal park returning through
the side door.

**Movement 3 — probate, both halves.** `grant frame to boss [onward]`
hands an estate to the executor; `case handoff(h)` + `adopt h as frame`
signs for it. Adoption copies hardware's descriptor into the slot the
heir's own name binds and clears the source — a copy, never a rebuild,
because rebuilding would re-derive an attenuation the heir does not get
to choose. Cost: **five stores**, and `frame[i]` addresses the inherited
memory immediately, because a joe region was always indirect through a
near-page pointer cell. Frozen table unmoved a third time: 2820 B /
171,532 instr / 479,275 cy / 13,281 switches.

| pre-registered claim | outcome |
|---|---|
| chain of custody | Screen → Cabinet → Archive, **one span of memory at every hop**; the Archive reads 6564 written by an actor that died two hops earlier |
| attenuation ends it | the same program minus `onward`: the executor adopts and reads, its own grant **refused** |
| domains must match | the same program with the Archive on core 1: the crossing **refused**, the heir handed nothing |
| the heir's own vocabulary | a program whose first message is tag 1 no longer handles its inheritance as that message |

**Two defects the second half found in the first.** Both were invisible
until something needed to *receive* an estate rather than send one.

The grant record was `$6772_0001` — the architected mark in the half no
dispatcher masks, and tag **1** in the half every dispatcher does. Since
tags are handed out from 1, every program's first message collided, and
joe's sole-case elision (which skips the tag test entirely) meant the
estate was handled as that message in silence, with a descriptor slot
read as a field. Fixed in both halves: the mark moved into the low 16
bits with a kind byte above it, and the elision now checks whether the
program grants at all — because a grant makes the RBC a sender that no
`message` declaration describes, which is exactly the precondition the
elision claimed. **An optimisation's precondition is a claim, and claims
go stale when the system grows a new kind of sender.**

And RAM is per-core, so a region's base is a core-local address — yet
the RBC granted across cores, handing the grantee a flawless capability
(right length, correct verbs, fresh token) over memory it never named.
Nothing malformed, so nothing complained. Movement 2 shipped it; its
test could not see it, because both parties sat on core 0. Regions now
may not leave their memory domain, which gives the rights word a third
companion to its two disciplines: **verbs attenuate by subset, dialects
compare by equality, domains must simply match.**

**The honest gap.** Probate runs end to end, but not yet to a
*successor*: `spawn` gives a supervisor no name for its child, so the
Cabinet can pass an estate to any peer it can name and not to the screen
it just started. A missing capability in supervision, not in transfer —
a supervisor that can bury a child but not write to one is only half a
parent.

## A4 movement 3, the other half of the parent — a supervisor names its child

The honest gap above, closed. `spawn Screen(1) as screen` binds a name
for the spawned child; the loader stages a capability aimed at the
child's RX ring — the exit link's twin, pointed down — so `grant frame
to screen` and `send screen, …` reach a successor, not just a wired
peer. The child gains `send boss, …` to match the `grant … to boss` it
already had. A whole parent: it can bury a child and write to one.

| claim | outcome |
|---|---|
| a supervisor can grant an estate to a child it spawned | ✓ down-grant reaches the named child, one succession recorded |
| the successor reads what the supervisor wrote | ✓ marker `6564` read through the inherited descriptor two contexts later |
| unnamed spawns cost nothing | ✓ supervise.joe byte-identical; only a named child reserves a slot |
| the frozen ASM baseline is untouched | ✓ 2820 B / 171,532 instr / 479,275 cy / 13,281 switches, a fourth time |

146 tests.

**What granting *down* taught us about time.** Up and down are not
mirror images, because a grant claims a descriptor slot in the grantee's
table, and the grantee's *existence* differs by direction. A child
grants up to a supervisor already alive, its table laid out; the grant
lands in a free slot. A supervisor grants down to a child that may not
have run yet — claim its slot before its init stages its own regions and
the child overwrites the inheritance, so `adopt` copies back an empty
descriptor. Nothing malformed; the same silent signature as the two
defects the first half found. The discipline rocci already implies
dissolves it: **a supervisor lends to a child that is already running.**
The screen announces itself to `boss` once its regions are staged, and
the Cabinet grants in reply — the request is the child saying the estate
now has somewhere safe to land. *You cannot inherit a house while you
are still being built.*

Still open, and the next increment: the *dynamic* spawn — naming a child
started inside a `serve` handler rather than the actor body — so the
Cabinet can hand the frame to a screen it starts on a transition, not
only at boot. Same name, later in time.

## A4.8 — the dynamic spawn: the same name, later in time

A4.7 named children at boot; A4.8 lets a `spawn` live inside a `serve`
handler, so a transition can start the next screen — the shape rocci's
Cabinet needs. No new opcode and no machine change: `SPWN` already
reused a fixed context and bumped its generation on restart. The whole
increment is in the compiler — a spawn's record index is now fixed by
statement identity in one canonical walk (body, then handler bodies,
recursing into nested blocks), so a `SPWN` reached through the case
ladder reads the slot the loader staged for that exact site, regardless
of emission order.

| claim | outcome |
|---|---|
| a screen spawned mid-`serve` can be named and lent the estate | ✓ Cabinet spawns in a `Kick` handler, grants the frame down, heir reads `6564` |
| one spawn site, fired twice, reuses one context | ✓ `SPWN` bumps `gen`; near page (and its RX ring) survives |
| the parent's capability outlives the incarnation bump | ✓ `send screen, Ping` lands on both lives; two Done reports (`cycles=2`) |
| body-spawn programs are untouched | ✓ supervise.joe byte-identical (crashes=2 hangs=1 lost=2, 5,366 cy) |
| the frozen ASM baseline is unmoved | ✓ 2820 B / 171,532 instr / 479,275 cy / 13,281 switches, a fifth time |

148 tests.

**Why the index had to change.** When every spawn lived in the body, its
record slot could be counted in body order, because that was also the
emission order. A handler spawn breaks the coincidence — the emitter
reaches handlers through region dispatch, then the case ladder, then the
timer body, an order no single source walk reproduces. So the slot is
fixed by the statement's identity (its pointer), assigned once and looked
up wherever the `SPWN` emits. *When a thing can appear in more than one
place, stop numbering it by where you happen to find it.*

**Why repeated spawns are safe.** A screen halts synchronously inside its
own burst, so it is dead before the Cabinet processes the message that
triggers the next spawn — the successor never restarts a living context.
And the ready-handshake is per-life, not per-boot: each incarnation
re-runs init, re-claims its descriptor slots, and re-announces itself,
because a restart resets the ring's contents while preserving the ring.
The capability is stable across lives; the estate's landing slot is
claimed afresh each life. *The house keeps its address while its tenants
come and go, and every new tenant still has to unpack before you hand
them the keys.*

With this, the Cabinet is expressible end to end — a boot screen,
transitions that spawn the next, a frame lent down each life and returned
by death. rocci-bird is no longer waiting on the language; what it waits
on now is a device row (display, pad, APU) and the PresentDone frame
clock — machine work, not language work.

## The device row opens: the display, and a completion that is a clock

rocci-bird's frame clock, in the flesh (sketch §2). A display is an
accelerator (§7.6) whose work is to present: a core grants it a frame
region, the region is hardware-owned until the completion, and one vblank
interval later `PresentDone` — the ordinary `$6772` grant completion,
routed by `case done(frame)` — hands the region back. No new joe surface:
the grant-message and completion-case machinery built for the matmul
accelerator (item 6) *is* the display's interface. The whole device is
machine.zig (a `display` accel kind) plus one loader line and a result
field; the language did not move.

| claim | outcome |
|---|---|
| a granted frame is presented and returned as a clock | ✓ screen presents 3 frames, each waiting on the last's `PresentDone` |
| the glass receives what the core drew | ✓ display checksum = 6566, the final `frame[0] = 6564 + 2`, rest zero |
| the loop is backpressure, not a caller | ✓ the screen cannot draw ahead — `send Present` blocks on `case done` |
| single-buffer is enforced at both levels | ✓ machine refuses a second Present (OWNED); the compiler locks the region first |
| matmul is unchanged by the shared completion path | ✓ matmul.joe checksum 379, bit-identical |
| the frozen ASM baseline is unmoved | ✓ 2820 B / 171,532 instr / 479,275 cy / 13,281 switches, a sixth time |

149 tests.

**Why the display is an accelerator, not a `dev.zig` device.** A `dev.zig`
device sees only a payload — it cannot read the granting context's region
memory. The display presents a *region*, so it lives with the accelerator
machinery that already reads regions under the deferred-read discipline
(revocation between grant and present turns into a clean reject, nothing
scribbled). The completion latency, which for the matmul is a compute
cost, is for the display the vblank interval — the backpressure that
paces the frame loop. Parked cycles are free, so a realistic period does
not inflate the instruction bill.

**The single-buffer refusal is the type-state lock's runtime twin (§2.3).**
The machine refuses a second Present while a frame is up (the region is
OWNED); well-typed single-region joe cannot even reach that refusal,
because the region is locked between grant and completion at compile
time. The static check is the early copy of the dynamic one — the healthy
direction — so the runtime guard is defence in depth, not a smell.

Next on the row: the **pad** (a device that pushes `Pad{buttons}` unasked
— input as messages the actor latches) and the **APU** (a fire-and-forget
`Tone` sink — sound as a send that expects no answer). With those and the
frame clock, rocci-bird's society is fully wired; what remains is the game
itself.

## The device row completes: the pad, and input as a subscription

The last device, and the only one that pushes. A WASM-4 game polls the
gamepad; a 6564 actor is pushed to (rocci §1). The mechanism turned out
to need nothing new: an actor subscribes with an ordinary A3.3 device ask
— `send pad, Poll{}`, where `Poll -> Pad` — and the pad, instead of
answering once, streams `Pad{buttons}` to the ask's reply window using
its echoed tag, one message per input frame. `case Pad(p)` matches them
like any message; the actor latches. A subscription is an ask whose
answer never stops coming, and the whole of it reuses the reply-window
wiring and tag convention already on the row.

| claim | outcome |
|---|---|
| an actor subscribes and the pad streams input | ✓ Game `Poll`s once, receives 3 `Pad` messages, latches each |
| pushes arrive in order | ✓ interval-apart, so the latched value ends at the last recorded (6) |
| the trace is deterministic — a recording replays | ✓ a fixed `[1, 4, 6]` trace; same seed, same run (§4, TAS) |
| pushes ride the fault-injected fabric | ✓ `deviceReply`, so a dropped push is a dropped input frame |
| the frozen ASM baseline is unmoved | ✓ 2820 B / 171,532 instr / 479,275 cy / 13,281 switches, a seventh time |

152 tests.

**Why a subscription, not a wiring.** The alternative — the loader
pre-wires the pad to one listener and looks up the `Pad` tag — needs new
machinery and binds input to a single actor for the machine's life, which
a screen-per-state game cannot use. Reading the ask as a subscription
reuses everything (the reply window is the push target, the echoed tag is
the `Pad` tag) and is dynamic: whichever actor `Poll`s is the one pushed
to, so a transition re-subscribes on spawn. v1 keeps one subscriber at a
time (the row's one-asker-per-device rule); many-subscriber fan-out is a
later refinement, not a new contract.

**The row, whole.** Display (frame clock), APU (sound sink), pad (input
stream) — rocci-bird's society is now fully wired, and every device
honors §7.5: the reference implementation is one of several the same
contract admits, and the actor cannot tell which silicon answers. The
frame clock is backpressure, the sound is fire-and-forget, the input is a
subscription, and all three are messages on the same fabric the actors
already live on. What remains is the bird itself — the Game actor's
physics, the pipes, the sprite blits — which is a program now, not a
machine or a language gap.
