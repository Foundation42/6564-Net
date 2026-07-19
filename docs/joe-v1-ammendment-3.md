# joe — v1 Amendment 3: The Device Conversation

**Status: adopted (Christian's read-through, 2026-07-19). Drawn from the harness retirement's expression gaps — mandel/periph/http had no joe voice — and the rocci-bird sketch, which uses half of what follows as if it already existed.**

*Verdict in one line: devices answer with the tag you gave them, bytes get a raw voice, `let` names what a burst may keep, and records give near-page state a shape.*

The tidy-up was the survey party: converting the hand-written corpus to
self-carried deployment showed exactly which programs joe cannot yet
say. mandel needs to *build* a line of output; periph needs to *hear* an
entropy well; http needs both. And rocci-bird — the north star — writes
`let` bindings, record types and device completions on every page. This
amendment is the road those surveys staked out.

---

## A3.1 `let` — burst-local bindings

v1 refused `let` on purpose: park-point liveness was item 4's open
experiment, and the sketch said so. Item 4 closed the question — there
is one register file, volatile at every park, and nothing compiled ever
needed more. So `let` now has semantics the machine can keep honest:

```joe
let flap = (buttons & (BTN1 | UP)) != 0
if !flap_held && flap { ... }
flap_held = flap
```

**A `let` lives for the rest of its burst and not one cycle longer.**
Every use must occur before the next park (`LSTN`, `YLD`, the serve
loop's end). A use that crosses a park is a compile error that names
the park:

```
flap does not survive the park at line 12 — a `var` does.
```

What `let` is *not*: a register promise. The compiler keeps it wherever
codegen likes — a register between clobber points, a scratch temp
across a `send` (a send is a doorbell, not a park; the binding
survives it, and how is codegen's business). The contract is the
*lifetime*, not the location. The A1.3 accountant prices whatever is
emitted, as always.

What it buys: intermediates without near-page traffic, names for the
frame-loop style rocci-bird is written in, and — the quiet part — a
type-level record of which values are burst-ephemeral and which are
actor state. `var` is who you are; `let` is what you're thinking.

## A3.2 Raw bytes out: `append`, `clear`, indexing, and sending a buf

Amendment 2 made bytes honest in one dialect: `pack` speaks struple,
canonically, to actors. But a teletype does not read struple, and
mandel's output row is not a tuple. Bytes need a second, *raw* voice —
and the two must never blur:

**`pack` speaks struple to actors; `append` speaks raw to devices.**

```joe
const pal = " .,:;~=+xoXO#%$&@"

var line buf [72]u8

clear line
for c in 0..64 {
    ...
    append line, byte(pal[n])       // one raw byte, low 8 bits
}
append line, "\n"                    // raw literal
send tty, line                       // the buf's current bytes, verbatim
```

- `const name = "…"` — named read-only byte data, staged after code
  the way string literals already are (and the on-ramp to §11's shared
  const pages, where rocci's sprites live).
- `b[i]`, `pal[i]`, `field[i]` — byte indexing as an expression: one
  byte, zero-extended. Over bufs, consts, and `bytes` message fields.
- `clear b` — length to zero; `append b, X` — X a literal, a
  `byte(expr)`, another buf, or a bytes field. Overflow is a compile
  error when the extents are static and the `pack_overflow` fault when
  they are not — Amendment 2's rule, unchanged.
- `send target, b` — the generalization of `send tty, "literal"`:
  length from the buf at send time. Raw send is for device targets;
  actors take messages, and the compiler holds that line.

This is the whole of mandel.joe's missing surface, and most of http's.

## A3.3 Devices answer with the tag you gave them

The gap: an entropy well's answer is eight raw bytes. `serve` matches
tags; the answer has none; therefore periph.joe cannot exist. The fix
is not new syntax — it is a convention the machine has already shipped
**twice**. The accelerator contract (item 6) begins with a reserved tag
word the silicon carries; grant completions come back architected as
`$6772`, and rocci-bird's whole frame clock — `case PresentDone(_)` —
is that convention wearing its display costume.

Generalize it (spec §7.3 addendum, the real decision in this
amendment): **an ask-style device request begins with a caller-tag
word; the device echoes it as the reply's first word.** The reply wears
the tag you gave it. Silicon never interprets the tag — it is caller
space, exactly like the accel contract's reserved word.

In joe, the pairing is declared where messages already live:

```joe
message Draw -> Rand { v u64 }        // ask the well, hear Rand
message Now  -> Time { t u64 }        // ask the clock, hear Time
message Read { sector u64 } -> Sector { data bytes }

actor Errand(tty addr, well addr, rtc addr) {
    send rtc, Now{}
    serve {
        case Time(x):                 // an ordinary case; no new form
            ...
    }
}
```

`send well, Draw{}` stages *Rand's* tag in the request's tag word; the
reply arrives as an ordinary tagged delivery; the serve ladder never
learns devices exist. One request in flight per device is the driver
discipline the corpus already keeps (the result is the ack), not a
language rule.

Costs, stated honestly:

- This **revises the §7 device request framings** (entropy, rtc, block,
  net gain the tag word). The hand-written periph.asm and http_get.asm
  update to the new framing and re-verify — the retirement gave us
  exactly the harness-free loop to re-measure them in.
- Devices that *push* unasked (the pad, the display row) are the same
  convention minus the request — their contracts name their tags. That
  is device-row design work (rocci's territory), not language work;
  A3 only guarantees they'll have a `serve` worth arriving in.
- The alternative spelling — a distinct `ask` verb instead of paired
  declaration — was considered and set aside: `->` keeps the request
  and reply in one place, and `serve` stays untouched. Overrulable at
  read-through.

## A3.4 Records — the rider rocci-bird asked for by name

Roc's `Animation : { last_updated, index, cells, state }` has no v1
home; messages are joe's only aggregates, and an animation is not a
message. The smallest fix:

```joe
struct Anim { last u64, index u64, cell u64 }

var anim Anim
anim.index = 0
anim = restart(anim)     // whole-record assign: word copies
```

A `struct` is named offsets into the near page — no pointers, no
nesting, scalar fields only, fixed layout, field access lowering to the
same slot arithmetic `var` already uses. It is a shape, not a heap.
(Functions like `restart` remain out of scope — see non-goals — but
records without functions still group state, and grouping state is
most of what Roc's record was doing.)

## A3.5 The loader's device row

joe_run's table grows to the full §7 row — `Entropy()`, `Rtc()`,
`Block()`, `Net()` beside `Console()` and the matmuls — with the reply
window staged the way asm_run's `reply` already does it: the device's
own PTT slot 0 aimed back at the asker's RX, driver wired to device
like any two actors. The RTC answers to token 0; it keeps no secrets.

## A3.6 What joe Cannot Say — additions

- **You cannot poll.** There is no read-a-device expression; you ask,
  you park, the answer is a delivery.
- **You cannot hear an untagged byte.** A reply without a declared
  shape has no case to land in — deliberate: every arrival is either a
  declared message or invisible transport business.
- **`append` cannot build struple** and `pack` cannot build raw bytes.
  Two dialects, one boundary, no dialect drift.
- **A `let` cannot cross a park.** If it must, it was a `var` all
  along, and the error message says so.

## A3.7 Grammar deltas

```
decl      := … | "const" IDENT "=" STRING
           | "struct" IDENT "{" field ("," field)* "}"
message   := "message" IDENT fields? ( "->" IDENT fields )?
stmt      := … | "let" IDENT "=" expr
           | "clear" IDENT
           | "append" IDENT "," append_src
           | "send" IDENT "," IDENT            // raw buf send
append_src:= STRING | "byte" "(" expr ")" | IDENT | IDENT "." IDENT
expr      := … | postfix "[" expr "]"          // byte index
           | IDENT "." IDENT                   // record field
```

## A3.8 Lowering table — additions

| construct | lowers to |
|---|---|
| `let x = e` | register/scratch value; liveness checked against park points; no near slot |
| `const s = "…"` | labeled `.byte` run after code (string-literal machinery, named) |
| `b[i]` | pointer + `LDA (p),Y`-shaped byte load, zero-extended |
| `clear b` | store 0 to the buf's len slot |
| `append b, …` | bounds check (static or `pack_overflow`), byte store(s), len update |
| `send t, b` | the `send_str` SQE with buf base and live length |
| `message A -> B {…}` | A's request stages B's tag in the tag word; B is an ordinary tag in the ladder |
| `struct` field | slot arithmetic off the record's near base |

## A3.9 Order of work, each step priced by a program

1. **`let`** — self-contained in the compiler; the corpus recompiles
   unchanged, then crunch/keys adopt it where it reads better.
2. **`append`/`clear`/indexing/`const`/raw send** — proven by
   **mandel.joe**: all 22 rows character-for-character against
   mandel.asm's output, the same oracle, third implementation.
3. **The echoed-tag addendum** — spec §7.3 text, the four device
   patches, periph.asm/http_get.asm reframed and re-verified, then
   **periph.joe**: the same transcript, the same RTC arithmetic.
4. **The device row in joe_run** (rides with 3), then **http.joe**:
   a real page on the teletype, the §7.5 story told from the
   language at last.
5. **Records** — last, independently landable, first consumed by the
   rocci-bird screens.

## A3.10 Non-goals, so the scope holds

Functions and byte views as parameters (rocci findings 2/3 — the
`draw_pipes(frame, …)` cluster) are **Amendment 4 material**: they
deserve their own argument, not a rider here. Likewise bitsets and
masks (ride with VSEL and its first workload), narrow scalars
(`u8`/`i32`/`f32` lanes), sized `bytes[N]` fields (the store-hardware
item), device *subscriptions* beyond push-contracts, and region
succession (Q9's fourth costume). Named so they're seen, deferred so
A3 ships.

---

*The machine already knew how to answer — the accelerators proved the
convention and the display row was always going to demand it. This
amendment just teaches joe to hold up its half of the conversation.*
