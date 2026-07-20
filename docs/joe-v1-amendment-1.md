# joe — v1 Amendment 1: Iteration

**Status: adopted. Supersedes the iteration constructs implied in the v1 sketch and resolves the mid-tier vector question.**

*Verdict in one line: `while` dies, `for` becomes replicated PAR, `bounded` becomes checkable, `map` stays pure.*

---

## A1.1 `while` is removed

`while` is the unbounded-compute construct, and unbounded compute fights the machine: parks, burst budgets, the watchdog. It is not in the language.

Unbounded iteration still exists — it is a **self-send loop**, the tail-recursion analogue:

```joe
actor Cruncher(work addr) {
    var state State = init()

    send self, Step{}

    serve {
        case Step(_):
            state = advance(state)        // one bounded slice
            if !done(state) { send self, Step{} }
            else            { send work, Result{state}; halt ok }
    }
}
```

This is strictly better than `while`: every iteration parks, so it is preemptible, budgeted, fairly scheduled, and observable in the CQ. The watchdog never has to guess whether the loop is progress or a hang — each slice answers for itself.

## A1.2 `for` is retained — as bounded, unordered replication

joe's `for` is not C's `for`. It is **occam's replicated PAR in Go's clothes**:

- **Bounded**: iterates a collection (or fixed range) whose extent is known at the loop head. No mutation of the iteration space from inside the body.
- **Unordered**: iterations carry no order dependency. The body's effects are sends and spawns — fire-and-forget onto a fabric that reorders anyway — plus writes to disjoint per-iteration state. The compiler may execute iterations in any order or stage them as one unit.
- **Collection-only**: there is no `for (;;)` and no loop-carried accumulator. Sequential accumulation is `reduce`; stateful iteration is an actor.

This is the silicon-honest construct: a bounded replication over sends is *exactly* what lowers to staged SQEs behind a single doorbell. The `chain { for ... }` idiom in §2.4 depends on it. The existing uses in the sketch — `for cfg in configs { spawn ... }`, the scatter chain, `for k in got.missing() { send ... }` — are all already in this shape.

## A1.3 Consequence: `bounded` is now enforced, not requested

With `while` gone and `for` bounded by construction, **every serve handler has a statically computable worst-case cycle count**. Therefore:

- The compiler computes the bound for every handler.
- `bounded N { ... }` is **required** exactly when the static bound exceeds the base burst budget — and rejected when `N` is less than the computed bound. You cannot understate your appetite.
- A handler within base budget needs no declaration, and the compiler will not accept a gratuitous one.

The v1 sketch said the compiler "insists you say it out loud." Amended: the compiler *checks your arithmetic*. "joe cannot express the bugs the machine cannot have" now covers unbounded handler compute at compile time; the watchdog remains as the runtime backstop for the bounds the analysis cannot see (data-dependent Tier-1 ops declare worst-case in the ISA table).

## A1.4 The vector package (mid-tier, adopted)

SIMD is a **data type with operators**, not a loop:

```joe
v = [1.0, 2.0, 3.0, 4.0]      // vector literal
w = v * 2.0                    // element-wise, scalar broadcast
z = v + w                      // element-wise add
m = v > 3.0                    // compare → mask vector
p = where(v > 3.0, v, w)       // lanewise select: v where the mask holds, else w

sum = v.reduce(+)              // reduction tree
top = v.reduce(max)
r   = v.permute([3, 2, 1, 0])  // shuffle

g = gather(rgn, [0, 2, 4, 6])  // non-contiguous, region-typed base
scatter(rgn, [0, 2, 4, 6], g)
```

Element-wise operators, `reduce`, `permute`, and `gather`/`scatter` lower to the Tier-1 vector unit directly. The programmer writes math; the lanes are the hardware's business.

## A1.5 `map` is pure — the polyfill stops at the core boundary

`v.map(fn)` is admitted with one restriction: **`fn` must be pure and vectorizable** (arithmetic, no sends, no spawns, no region access beyond its element). It lowers to SIMD where the unit fits, unrolled scalar where it doesn't. Nothing else.

The rejected alternative — a polyfill chain of SIMD → actor fork → peripheral — is rejected on §4 grounds. A map that can lower to a peripheral smuggles a synchronous call into expression position: a hidden grant, a hidden park, and a completion arriving at a case the programmer never wrote. Then the peripheral dies mid-map and the exit has nowhere honest to go. §7.5's polyfill principle holds at the *message* level precisely because the completion is a visible `case`; it cannot be honored inside an expression.

Consequently the tier boundary stays where the sketch's §2.5 put it: if the data is big enough to want a peripheral, the programmer writes the `grant` and the completion case, and the type-state protects the region in between. Big math is a conversation, not an expression.

## A1.6 What joe Cannot Say — additions

- No `while` (unbounded iteration is a self-send loop, one park per slice).
- No ordered or loop-carried `for` (accumulation is `reduce`; stateful iteration is an actor).
- No handler whose worst-case compute is undeclared when it exceeds base budget — and no `bounded N` that understates the computed bound.
- No effects inside `map` (a map that could send is a call in disguise).

## A1.7 Grammar deltas

```
stmt      := send | spawnst | chainst | bounded | assign | if | for
           | "quiesce" | "halt" ("ok" | "err")           // unchanged: no while
for       := "for" "(" Ident ("," Ident)? ")" "in" expr block   // bounded, unordered
vexpr     := "[" expr ("," expr)* "]"                    // vector literal
           | expr vop expr                               // element-wise; scalar broadcasts
           | expr "." "reduce" "(" rop ")"
           | expr "." "map" "(" purefn ")"
           | expr "." "permute" "(" vexpr ")"
           | "where" "(" expr "," expr "," expr ")"        // lanewise select (mask, a, b)
           | "gather" "(" expr "," vexpr ")"
scatterst := "scatter" "(" expr "," vexpr "," expr ")"
vop       := "+" | "-" | "*" | "/" | "==" | "<" | ">" | "&" | "|" | "^"
rop       := "+" | "*" | "min" | "max" | "&" | "|" | "^"
```

## A1.8 Lowering table — additions

| joe | 6564 |
|---|---|
| `for x in c { send/spawn ... }` | replicated SQE staging; inside `chain`, one LINK chain, one doorbell |
| self-send loop | `SEND` to own PTT slot; one park per slice; watchdog-friendly by construction |
| vector literal / element-wise op | Tier-1 vector unit ops (extended page), worst-case cycles in ISA table |
| `reduce` | in-core reduction tree, O(log n) |
| `where(cond, a, b)` | `VFCMP` mask + blend `b + mask·(a − b)` (`VFSUB/VFMUL/VFADD`) — no `VSEL`, the mask that counts chooses; exact when `a − b` is representable |
| `map(purefn)` | SIMD if lanes fit, else unrolled scalar — never fork, never peripheral |
| `gather` / `scatter` | region-typed indexed load/store |
| handler bound check | compile-time cycle sum vs base budget; `bounded N` mandatory iff exceeded, rejected if `N` < computed bound |

---

*The language got smaller in what it can express and larger in what it can promise. Matt would have approved of the trade.*