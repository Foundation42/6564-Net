# joe — v1 Sketch: Idiomatic Programs and Lowering

**A small language for the 6564-Net. Go's clothes, Erlang's soul, occam's discipline.**

*Design rule: the constructs are the silicon. joe cannot express the bugs the machine cannot have.*

---

## 1. The Two Words That Matter

- **`var`** — actor state. Lives in the near page, survives every park, survives nothing else (a restart clears it, as it should).
- **`let`** — transient. Lives in registers; the compiler spills it across a park only if liveness says it must. This *is* the bank-collapse convention, surfaced as a keyword.

Everything else follows: an `actor` is a context, `serve` is the canonical receive loop, `after` is a fabric timer, exits are messages, and there are no pointers between actors because there is nothing an address could honestly mean except a capability.

---

## 2. Idiomatic joe

### 2.1 Reliable ping over a lossy fabric

```joe
message Ping { seq u32 }
message Pong { seq u32 }

actor Pinger(peer addr, rounds u32) {
    var seq u32 = 0

    send peer, Ping{seq}                  // opening move

    serve {
        case Pong(p) where p.seq == seq:
            seq += 1
            if seq == rounds { halt ok }
            send peer, Ping{seq}

        case Pong(_):
            // stale duplicate: delivery already consumed the buffer,
            // serve reposts it — there is nothing to do, and nothing
            // you could forget to do

        after 800:
            send peer, Ping{seq}          // retransmit; the timer re-arms itself
    }
}
```

Notice what's *absent*: no transport-ack handling anywhere. `send` is fire-and-forget at the language level; the runtime consumes the CQ acknowledgment for exactly one purpose (buffer release) and shows it to no one. The end-to-end argument is the default, not a discipline.

### 2.2 A supervisor — death is a message

```joe
actor Boss(configs []WorkerCfg) {
    for cfg in configs {
        spawn Worker(cfg) restarts 3 watchdog 10_000
    }

    serve {
        case exit(w, crash(code)):
            log "worker {w.id} crashed ({code}); on life {w.life}"
        case exit(w, hung):
            log "worker {w.id} hung; the leash worked"
        case exit(w, abandoned):
            log "worker {w.id} out of restarts — abandoned, honestly"
    }
}
```

`restarts 3` is policy, not code: the runtime wires the exit link, respawns on death up to the budget, and the obituaries still arrive as ordinary messages so the supervisor can *observe* what it no longer has to *do*. `hung` is just a fault code — the watchdog made the invisible failure ordinary.

### 2.3 A pipeline stage — backpressure by silence, termination as a phase

```joe
actor Stage(up addr, down addr) {
    var expect u32 = 0
    var hold Item? = nil                  // one item in flight downstream

    serve {
        case Item(i) where i.seq == expect && hold == nil:
            send up, Ack{i.seq}           // ack on ownership — hops overlap
            hold = transform(i)
            expect += 1
            send down, hold!

        case Item(i) where i.seq < expect:
            send up, Ack{i.seq}           // re-ack the past, never the future

        case Item(_):
            // out of order, or no room: say nothing.
            // silence IS backpressure — upstream's timer is the retry loop

        case Ack(a) where hold != nil && a.seq == hold!.seq:
            hold = nil

        case Done(d):
            send up, Ack{d.seq}
            send down, Done{d.seq + 1}
            quiesce                       // termination is a phase, not an instruction

        after 600:
            if hold != nil { send down, hold! }
    }

    quiesce {
        case Item(i) where i.seq < expect:
            send up, Ack{i.seq}           // a lame duck serves re-acks;
                                          // timers die, stragglers converge,
                                          // the machine goes quiet instead of staying awake
    }
}
```

### 2.4 Scatter-gather — the result is the ack

```joe
actor Coordinator(workers []addr, task u64) {
    var got bitset = bitset(len(workers))
    var results [8]u64

    chain {                               // staged as one LINK chain: one doorbell,
        for (k, w) in workers {           // zero instructions on the happy path
            send w, Ask{task, k}
        }
    } on_break(k, cause) {
        // chain_cancelled arrives here as a message; the straggler
        // timer below re-asks individually anyway — the chain is an
        // optimization, never a dependency
    }

    serve {
        case Reply(r) where !got[r.k]:
            got[r.k] = true
            results[r.k] = r.value
            if got.all() { halt ok }

        case Reply(_):
            // duplicate — idempotence already made it harmless

        after 900:
            for k in got.missing() { send workers[k], Ask{task, k} }
    }
}

actor Squarer(k u32) {
    serve {
        case Ask(a):
            send a.from, Reply{k, a.task * a.task}
            // stateless: recompute on duplicates. No ack protocol at all —
            // choosing WHAT to make reliable is the protocol design
    }
}
```

Every delivered message carries `.from` — the fabric already knows, so the language admits it.

### 2.5 The tiers, together — bounded compute and a granted region

```joe
actor Splatter(tpu addr) {
    var frame region [1_048_576]f32       // registered region: token minted here,
                                          // grants ride sends, completions release

    serve {
        case Camera(c):
            bounded 40_000 {              // WDEX: "this block is long, and I said so"
                project(c, frame)         // Tier-1 vector math, in core, on the clock
            }
            send tpu, MatMul{grant frame} // Tier-2: region granted; frame is now
                                          // hardware-owned — joe won't let you touch it

        case MatMulDone(_):
            present(frame)                // the completion WAS the release fence
    }
}
```

Between the `grant` and the `MatMulDone`, `frame` is inaccessible — not by convention, by type: a granted region's type changes until the matching completion case rebinds it. The §6.2 ownership rule, enforced at compile time.

---

## 3. Lowering Table — construct to silicon

| joe | 6564 |
|---|---|
| `actor` | a context: near page + run-queue entry + control block |
| `var` | near-page slot; survives parks and nothing else |
| `let` | register-transient; spilled across parks only if live |
| `serve { … }` | `LSTN` → `CQPOP` → tag dispatch → repost → loop |
| `case T(x) where g:` | tag compare + guard branch |
| `after N:` | auto-rearm `SEND` to the black-hole PTT slot |
| `send a, M{…}` | `TXR` (≤ 8 bytes) or `SEND` (larger); ack consumed by runtime for buffer release only |
| `.from` | delivery source coordinates, surfaced |
| `spawn … restarts R watchdog W` | `SPWN` + exit link + budgets in the privileged control-block stripe |
| `case exit(w, cause):` | exit completion records; `hung` = watchdog fault code; `w.life` = incarnation |
| `chain { … } on_break` | staged SQEs + `LINK`; `chain_cancelled` records dispatched to `on_break` |
| `bounded N { … }` | `WDEX #N` at block entry; base budget restored at next park |
| `quiesce` / `quiesce { … }` | lame-duck serve: timers not re-armed, restricted case set |
| `region` / `grant` | registered region (base, len, token, ownership bit); grant-on-send, completion as release fence; compile-time inaccessibility while granted |
| `halt ok` / `halt err` | `HLT`; obituary posts via exit link |

## 4. What joe Cannot Say

The negative space is the language's real specification:

- No pointers between actors; no shared mutable state (there is no syntax for it).
- No synchronous call to another actor (there is no expression whose value is "wait for a reply" — you `send`, and a reply is a `case`).
- No touching a granted region (type-state).
- No transport-ack visibility (the runtime owns the CQ ack; end-to-end evidence is all you can branch on).
- No unbounded compute inside `serve` without a `bounded` declaration (the watchdog will keep you honest either way; the compiler just insists you say it out loud).

## 5. Grammar Core (EBNF-lite, v1)

```
program   := (message | actor)*
message   := "message" Ident "{" (field)* "}"
actor     := "actor" Ident "(" params? ")" "{" var* stmt* serve quiesce? "}"
var       := "var" Ident type ("=" expr)?
serve     := "serve" "{" handler* "}"
quiesce   := "quiesce" "{" handler* "}"
handler   := "case" pattern ("where" expr)? ":" stmt*
           | "after" Int ":" stmt*
stmt      := send | spawnst | chainst | bounded | assign | if | for
           | "quiesce" | "halt" ("ok" | "err")
send      := "send" expr "," Ident "{" args? "}"
spawnst   := ("let" Ident "=")? "spawn" Ident "(" args? ")"
             ("restarts" Int)? ("watchdog" Int)?
chainst   := "chain" block "on_break" "(" Ident "," Ident ")" block
bounded   := "bounded" Int block
types     := u8..u64 | f32 | f64 | addr | bitset | [N]T | T? | region [N]T
```

No generics, no closures, no GC, no exceptions (exits are the exceptions, and they're messages). Compiler: recursive descent → typed AST → park-point liveness → `.asm` text → asm.zig. One binary, same repo, same comptime ISA table.

---

*Matt walked so joe could run rings — sixty cycles at a time.*
