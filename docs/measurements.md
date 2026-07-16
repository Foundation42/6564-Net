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
