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

Christian's `docs/joe-v1-ammendment-1.md` (worked out with Claude Chat,
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
