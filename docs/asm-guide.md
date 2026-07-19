# Writing 6564 assembly — the field guide

This is the guide for writing programs the machine can run *by itself*:
a single `.asm` file (or a small family joined by `.use`) that carries
its own deployment and runs with

```sh
sim6564 run program.asm [seed] [loss_ppm4k] [trace] [scorch]
```

no per-program harness, no loader code, no Zig. It covers the assembler,
the contract directives, the `.system` block, and what the loader
guarantees — with the lessons the corpus paid for along the way.

The architecture itself is spec territory
([6564-net-architecture-v2.6.md](6564-net-architecture-v2.6.md));
the ISA is one declarative table (`src/isa.zig`) and the assembler
(`src/asm.zig`) is driven by it, so the mnemonic list in the table *is*
the reference. This guide is about the writing.

## 1. The shape of a program

A runnable program has four layers, usually in this order:

```asm
; prose — what this program proves, and how it thinks

        .actor Name(…)          ; the contract: params, rings, cells
        .ring …
        .var …

        .system                 ; the deployment: instances and wiring
        …
        .endsystem

        .org $1000              ; the code
        …
```

The prose matters. Every program in the corpus opens with *why it
exists*; the contract formalizes the old "Harness contract" comment;
the code stays exactly as a 6502 hand would write it. Directives emit
no bytes and change no encodings — a file's code assembles identically
with or without its contract, which is why harnesses like `demo_dies`
can keep loading `ring_node.asm` raw.

## 2. Assembler quick reference

Two passes, forward references fine, `;` comments, labels with `:`,
`NAME = expr` equates. Numbers: decimal, `$hex`, `%binary`,
underscores allowed. Expressions are `term`, `term + term`,
`term - term`.

```asm
LDA #42             ; imm8 (sign-extended); picks imm8 when it fits
LDA ##$FF00_0000    ; imm64 (## forces wide)
LDA $8F8            ; near page (< $1000)
LDA !buffer         ; absolute (! forces; bare exprs ≥ $1000 are absolute)
LDA $8F8,X          ; near indexed
LDA (ptr)           ; near-indirect        LDA (ptr),Y   post-indexed
TXR (ptr),A         ; send A through the window pointer at near ptr
BEQ done            ; rel16 from the next instruction
SEND 0              ; desc — one-byte descriptor slot
CAPLD 3, ($40)      ; caps — PTT slot, near address of the entry image
VFADD 0, 1          ; vector register pair packed into one desc byte
.qword v,…          ; data: 64-bit words     .byte v,…     .ascii "…"
```

Extended-page opcodes (scalar FP, vectors) assemble automatically with
their `$42` prefix; you just write the mnemonic.

## 3. The contract: directives

The contract states facts the code already assumes — pinned addresses,
expected staging, named result cells. The loader (`src/asm_run.zig`)
executes it. The whole vocabulary:

### `.actor Name(param spec, …)`

Declares the actor and its parameters. Each param is
`name kind where`, and the *where* is the heart of it:

| spelling            | meaning |
|---------------------|---------|
| `con cap`           | grant only — the code builds target addresses itself (SQE routing by prefix match); the loader just ensures a capability exists |
| `con cap = 0`       | pinned PTT slot 0 — the code baked window constants, the slot number is contract |
| `next cap @ $840`   | loader picks a slot (deduplicated per core and target) and stages the window pointer at the cell — the code does `TXR ($840),A` |
| `ent cap = 1 reply` | additionally wires the *target device's* own PTT slot 0 back at this actor's RX ring — how a device answers |
| `ws cap[] @ $A00`   | a whole group: one window pointer per member at `$A00+8j` (singletons only) |
| `fuse arg @ A`      | a number, arriving in the accumulator at spawn |
| `rounds arg @ $2600`| a number, staged at a near or RAM cell before spawn |

Cells below `$1000` are near-page (per-context); at and above it,
core RAM. Replicated actors may not use RAM cells (all replicas on a
core share its RAM) — keep per-replica staging in the near page.

### `.ring slot kind cap=N [base=addr] [auto_repost] [post=N size=M] [grant]`

A descriptor the loader stages. `kind` is `sq`, `cq` or `rx`; `cap`
must be a power of two. Pin `base=` **only** when the code addresses
the storage absolutely (a staged SQE at `$2400`, self-staged RX entries
at `$2100`); otherwise let the loader allocate — pinned storage is a
claim, and a replicated actor cannot make it. `post=N size=M` posts N
landing entries with loader-allocated buffers, cookie = buffer address.
`grant` starts the tail at the post count (a sink that never RECVs).
RX rings carry the machine token (`$6564`); SQ/CQ carry 0; every
ring's companion is the declared CQ.

### `.timer = slot period=N` / `.timer @ cell period=N`

The black hole (spec §6.3): a capability whose sends can only time
out — the fabric as a clock. `=` pins the PTT slot the code baked;
`@` stages a window pointer. The period becomes the fabric's
send-timeout. **One period per system** — two different `after`s is a
deploy error (open spec item, §10). A system with no `.timer` gets the
mesh default horizon of 2000 cycles, which is what the hand-written
corpus measured its canon numbers against.

### `.stage addr v0, v1, …`

Qwords written before spawn — constants the code expects to find
(f64 bit patterns, tables, expected counts).

### `.reserve addr len`

RAM the program owns: scratch buffers, request cells, landing space
the code addresses directly. The loader allocates nothing on top of
it. **If the code writes it, reserve it** — this rule was learned
three times in one afternoon (see §7).

### `.var name addr`

A named readback cell. After the run, its value appears in the report
next to the instance: `p = Ping … final=8 retransmissions=3`. Near
cells read per-context; RAM cells read from the core.

### `.use "file.asm"`

Another actor's source joins the system, resolved relative to the lead
file. Each file declares exactly one `.actor`.

## 4. The `.system` block

The deployment, in joe's system-block grammar — the same parser, the
same dialect the whole machine uses. Between `.system` and
`.endsystem`, lines are captured verbatim for joe's planner:

```asm
        .system
        coord = Coord(ws, 8) on 0
        ws = Worker[8](coord)
        con = Console()
        .endsystem
```

- **Instances**: `name = Actor(args…)`, optionally `on N` to pin a
  core, `Actor[N](…)` for N replicas. Args are integers, instance
  names (capabilities), or `index` (each replica gets its number).
- **Placement**: `on N` wins; singletons take fresh cores; replicas
  pack fresh cores, up to 200 contexts each, and never share a core
  with another declaration (co-residence starves the minority).
- **Declaration order is spawn order, reversed.** The loader spawns
  the *last* declaration first, so servers declared later are parked
  and listening before openers move. Declare the injector/source/
  driver **first**. This is the corpus's oldest structural lesson.
- **Devices** are instances of different silicon: `Console()`,
  `Entropy()`, `Rtc()`, `Block()`, `Net()`, `Matmul()`,
  `MatmulRemote()` — named like actors, wired like actors, no
  context. The RTC answers to token 0; it keeps no secrets.
- **Code loads once per (core, program).** Two hundred ring nodes on
  one core share one code page — a "process" is a register bank, not
  a copy of the text.

## 5. What the loader guarantees

In order: it assembles every source; reads the lead's `.system` with
joe's planner; places instances; computes a layout in which everything
pinned or reserved is untouchable and ring storage, landing cells and
a 256-byte stack per context are allocated above it; builds the
machine; attaches devices; wires capabilities (pinned slots exactly
where the contract says, free slots deduplicated per core and target);
stages rings, landing entries, params, timer windows and `.stage`
cells; spawns in reverse declaration order; runs to quiescence; and
reads back `.var` cells, console text, cycles and fabric stats into
the same report joe programs get.

Addresses never change cycle counts on this machine — only collisions
would, and collisions are deploy errors, not mysteries.

## 6. Running and reading the report

```sh
sim6564 run src/programs/asm/ring_node.asm            # defaults: seed $6564, loss 25%
sim6564 run src/programs/asm/ping.asm 0xBEEF 2048     # seed, loss/4096
sim6564 run src/programs/asm/mandel.asm 0x6564 0      # loss 0 = clean fabric (dup off too)
```

The verdicts: `all instances halted` (everyone finished), `quiescent —
the work is done, the servers are parked` (servers legitimately wait
forever), `quiescent, with the dead left where they fell` (faults —
which supervision may intend), `DEADLOCK` (parked with work
undelivered), `hit max_cycles`. A parked server is not a bug; a parked
opener is.

## 7. Lessons the corpus paid for

- **Reserve what you write.** The loader places its allocations above
  everything the contract mentions — code, pins, stages, reserves. A
  scratch buffer mentioned nowhere *will* eventually be under a CQ or
  a stack. periph faulted on a request cell, mandel would have pushed
  return addresses into its line buffer, pong's echo buffer sat under
  a nominal stack. `.reserve` exists because of all three.
- **Pin only what the code pinned.** A pinned base or slot is part of
  the contract because the code baked the constant. If the code reads
  a window pointer from a cell, use `@` and let the loader choose —
  that's what makes the wiring reusable at any scale.
- **The result is the ack; the reply is the flow control.** Nothing in
  the vocabulary stages transport acks, because transport is the
  machine's business. Stop-and-wait on *answers*, re-ask on timer
  ticks, make workers idempotent.
- **Openers first.** If it sends the first message, declare it first;
  the loader will start it last.
- **A send-timeout is not an error** — it is the clock. The black hole
  is the cheapest timer the fabric can sell you.
- **Check the numbers both ways.** Every conversion in the corpus was
  verified against its old harness at the same seed and shape —
  ping/pong to the cycle, mandel to the character, the ring to the
  60.0-cycles-per-pass marginal. When a conversion disagrees with its
  harness, the conversion is wrong until proven otherwise.

## 8. A worked example

`ring_node.asm`, whole. One actor, eight instances, and Armstrong's
challenge runs harness-free:

```asm
        .actor RingNode(next cap @ $840, fuse arg @ A)
        .ring 1 cq cap=4
        .ring 2 rx cap=2 auto_repost post=2 size=8
        .var finisher $850

        .system
        n0 = RingNode(n1, 800) on 0     ; the injector — declared first,
        n1 = RingNode(n2, 0) on 0       ;   spawned last
        n2 = RingNode(n3, 0) on 0
        n3 = RingNode(n4, 0) on 0
        n4 = RingNode(n5, 0) on 0
        n5 = RingNode(n6, 0) on 0
        n6 = RingNode(n7, 0) on 0
        n7 = RingNode(n0, 0) on 0       ; the ring closes
        .endsystem

        .org $1000
        RECV 2              ; grant landing space before anything moves…
        RECV 2              ; …both buffers; AUTO_REPOST sustains them
        CMP #0
        BEQ serve           ; not the injector
        TXR ($840),A        ; light the fuse: pass 1 departs
serve:  LSTN 1
        CQPOP 1
        BEQ serve
        …
```

Eight banked contexts, one code page, a window pointer each, and a
message that comes home 800 passes later at 60 cycles a pass —
exactly what the hand-wired harness measured, because the contract
*is* the harness, written down.
