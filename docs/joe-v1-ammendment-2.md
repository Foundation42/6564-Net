# joe — v1 Amendment 2: Bytes, Views, and Tuples

**Status: draft for adoption. Brings struple into joe as the tuple encoding, and byte views as the sub-structure story. A companion discussion note (D1, non-normative) records the key-as-location idea for the kernel's table.**

*Design rule continuation: bytes are honest, views are indices, and meaning lives only at the endpoints. The store deals in bytes it cannot read; the actors deal in values the store never sees.*

---

## A2.1 Byte buffers

A buffer is a fixed-capacity byte store with a named backing. There are two backings, both of which already exist:

```joe
var key buf [64]u8                    // near-page buffer: small, hot, survives parks
var blob region [1_048_576]u8         // registered region: large, grantable (§6.2)
```

A buffer value is `(backing, offset, len)` — capacity from the declaration, length tracked by the compiler or a near-page slot. There is no pointer to a byte anywhere in the language; there is only a named backing and arithmetic against it.

## A2.2 Views

A `view` is a zero-copy `(offset, len)` window over a buffer or region. struple's own law — *every sub-view is itself a valid struple buffer* — makes views compose and recurse without ever copying:

```joe
let v = key.view()                    // whole-buffer view
let h = v.head()?                     // first element, zero-copy
let t = v.tail()?                     // everything after it
let n = v.count()?                    // data-dependent: A1.3 applies
```

Views **borrow**. A view's validity is tied to its backing's ownership, and the type-state extends transitively: when a region is granted (§6.2), every view into it becomes inaccessible until the completion rebinds the region. The compiler tracks this the same way it tracks the region itself.

**Views do not cross actor boundaries in v1.** Sending a view would be a sub-grant — a capability-narrowing operation on a region — and that is the same open question as `.from`: capability transfer, already earmarked as the kernel's first requirement. Until the kernel answers it, data crosses the boundary as bytes (copied into the message) or as a whole-region grant. No half-measures smuggled in.

## A2.3 Tuples

struple is joe's tuple encoding. A tuple literal packs into a declared buffer:

```joe
var key buf [64]u8

pack key, ("users", user_id, "profile")   // struple bytes, canonical
```

- **Constant segments pre-pack at compile time** into the code page; only variable elements are encoded at runtime. `("users", id)` costs one block copy plus one integer encode.
- **Capacity is checked**: when all element widths are statically known, overflow is a compile error; when data-dependent (strings, bytes), overflow is a fault code (`pack_overflow`) — the actor crashes honestly and the supervisor hears about it.
- **Canonical only.** joe's packer emits the canonical encoding, always. There is no syntax for an insertion-ordered map — as the wire format prescribes, if you need key order, you say so with an array of `[key, value]` pairs. One value, one byte sequence: the property that makes replay, dedup, and content-addressing free is not optional.

### The subset manifest

joe v1 speaks a declared subset of the type tower:

| tower | joe v1 | note |
|---|---|---|
| nil, bool | ✓ | |
| int (fixed, ≤ 8-byte magnitude) | ✓ | full u64/i64; excess-form negatives per the wire spec |
| f32, f64 | ✓ | Tier-0 FP; order-transform on pack/unpack |
| string, bytes | ✓ | 0x00-termination and escaping in the packer/reader |
| array | ✓ | nesting via views |
| timestamp, uuid | ✓ | fixed-width; trivial |
| int (9–16 byte, ±big), decimal | reserved | multi-word arithmetic has not earned its silicon yet |
| map, set | reserved | canonical sort-on-pack wants scratch space; revisit with the store workloads |

**Skip is total even where decode is partial.** Self-delimitation means the reader can *skip* any valid element of the full tower, including types it cannot decode. A joe program handed a decimal doesn't corrupt or wedge — it steps over it and says so. Forward compatibility as a structural property, not a version field.

## A2.4 Prefix patterns

The best consequence of canonical + lexicographic: **matching a structured key is memcmp.** Amendment 2 adds tuple patterns to `case`:

```joe
serve {
    case Get(g) where g.key is ("users", ?id, ..rest):
        // constant prefix ("users") compiled to one pre-packed memcmp;
        // ?id decodes and binds one element; ..rest binds the remainder view
        send store, Read{grant g.key}

    case Get(g) where g.key is ("posts", ?post_id):
        // exact match: prefix memcmp + one bind + end-of-stream check

    case Get(_):
        send g.from_cap, NotFound{}
}
```

- Constant segments — however many, wherever contiguous — fuse into a single memcmp against pre-packed code-page bytes.
- `?x` decodes and binds exactly one element (subset types only; a non-subset element fails the match, it does not fault).
- `..rest` binds the remaining bytes as a view; omitting it requires end-of-stream.

**Lowering is A1.3-exact.** The memcmp length is a compile-time constant; each `?x` bind is charged at the declared worst-case width of its position's type. A typical key match is statically boundable and needs no `bounded` declaration. Zero-alloc, zero-decode dispatch on structured keys — the struple analogue of pattern-matching with string interpolation, and it costs what a tag compare costs, scaled by key length.

## A2.5 The substrate is a peripheral

**Decision (on the record): the store is a §7 device.** An actor at mesh coordinates, reached by `SEND` through a PTT capability, speaking messages whose key and value payloads are struple bytes. The device contract, minimally:

```joe
message Put  { key bytes, val bytes }
message Get  { key bytes }
message Scan { lo bytes, hi bytes }       // half-open [lo, hi); memcmp bounds
message Item { key bytes, val bytes }     // scan results stream as messages
message Done { }                          // termination is a phase, here too
```

- The store orders, indexes, and range-partitions on **raw bytes**. It never decodes a key. memcmp is the entire comparator, and memcmp is a bounded byte loop — the store needs no type knowledge, no schema, no versioning handshake.
- **§7.5 holds with room to spare**: the polyfill *is* the existing radix engine, reached through the network window on the same contract. Silicon — or a dedicated node, or the battle-tested Zig implementation running on the host — is an optimization, never an interface. joe cannot tell, and that is the point.
- **Determinism declaration** per the tiered bar: a single-node store declares deterministic; a replicated store declares its merge semantics (radix's LWW gossip, when it's behind the contract), and the application programmer chooses mitigations where ordering matters. The device says what it is; nothing pretends.

The store itself is **not language**. joe carries the client surface — buffers, views, tuples, prefix patterns — and the kernel gets its first real tenant service without joe growing a single storage construct.

## A2.6 What joe Cannot Say — additions

- No pointer to a byte (a view is `(offset, len)` against a named backing).
- No view crossing an actor boundary (sub-grant is kernel capability work; until then, copy or grant whole).
- No non-canonical encoding (there is no syntax for it).
- No decoding without the A1.3 discipline (element counts are data; the bound checker and the watchdog split the work exactly as Amendment 1 laid down).
- No silent mangling of unknown types (skip is total; decode is a declared subset; a failed `?x` bind fails the match, honestly).

## A2.7 Conformance

The joe/6564 implementation is struple's **thirteenth**, and it inherits the proof style of the house:

- The suite drives a **filtered `vectors.json`** — every corpus entry within the subset manifest must reproduce byte-identically in both directions, on the simulator, under `scorch`.
- A **skip-conformance pass** runs the *full* corpus: every vector, including reserved types, must be skippable without fault, with correct element counts.
- The subset manifest is published next to the implementation list, the way the wire spec reserves its code points: explicitly, with the tower's shape visible.

`vectors.json` joins `mandel.asm` and `scorch_parks` in the oracle drawer: language-neutral, pre-registered, no inspection required.

## A2.8 Grammar deltas

```
types     := ... | "buf" "[" Int "]" "u8" | "view" | "bytes"
packst    := "pack" Ident "," tuple
tuple     := "(" tupel ("," tupel)* ")"
tupel     := literal | Ident                       // constants pre-pack
pattern   := ... | Ident "is" tpat
tpat      := "(" tpel ("," tpel)* ("," "..‌" Ident)? ")"
tpel      := literal | "?" Ident
viewexpr  := expr "." ("head" | "tail" | "count" | "at" "(" expr ")"
           | "take" "(" expr ")" | "view" "(" ")") "?"?
```

## A2.9 Lowering — additions

| joe | 6564 |
|---|---|
| `buf [N]u8` | near-page slab + length slot |
| `view` | (offset u16/u32, len) pair; no pointer, ever |
| `pack` constant segment | code-page block copy of pre-packed bytes |
| `pack` variable element | subset encoder (Tier-1 scalar; excess-form ints, order-transformed floats, 0x00-escape for string/bytes) |
| `is ("k", ?x, ..r)` | fused memcmp of pre-packed prefix (compile-time length) → per-element bind decodes (charged at declared worst-case) → view bind |
| view navigation | bounded element-skip loops; data-dependent counts flagged per A1.3 |
| store contract | ordinary §7 device messages; keys/values as bytes; radix polyfill through the network window, token-for-token per §6.2 |

---

---

## D1 (discussion note, non-normative): Key as Location

*Recorded for the kernel's table. Nothing below is v1 joe or v2.x silicon.*

Ordered keys mean contiguous ranges. Contiguous ranges can map to mesh coordinates. So a struple prefix could be a **routing prefix**: the keyspace range-partitioned across the fabric, a prefix-to-coordinate map resident where the PTT already lives, and `send` addressed *to the key* — the fabric resolving which actor owns that range, the way it already resolves which node owns an IPv6 window.

What falls out if it works:

- **Location transparency meets lexicographic order.** The key is the name is the address. A `Scan{lo, hi}` becomes a scatter across exactly the coordinate span that owns `[lo, hi)` — the chain construct already knows how to stage that.
- **Migration is capability handoff.** Moving a range between nodes is re-pointing a prefix entry and transferring the backing region — which is the sub-grant question (A2.2) and the `.from` question wearing a third costume. All three are the same kernel requirement: capability transfer with a paper trail.
- **The store peripheral scales sideways for free.** One store actor per range, the prefix map in front, the client contract unchanged — §7.5 again, one level up: *sharding is an optimization, never an interface.*

Open questions, honestly held: who owns the prefix map (PTT stripe vs. kernel actor); split/merge of hot ranges without breaking in-flight sends (a lame-duck phase for a *range* — quiesce, but for territory); and whether range ownership interacts with the tiered determinism bar (a deterministic single-owner range vs. a replicated one declaring merge semantics).

This note asks for no opcodes and no syntax. It asks to be remembered when the kernel starts assigning names to things.

---

*Twelve implementations agreed on every byte. The thirteenth gets to disagree with nothing and prove it under scorch.*