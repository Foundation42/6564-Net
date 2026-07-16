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
