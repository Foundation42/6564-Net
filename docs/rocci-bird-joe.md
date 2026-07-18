# rocci-bird.joe — a Reimagining Sketch

**The WASM-4 flappy bird, rethought as a 6564 program. Not a port — a translation of *architecture*. The Roc original is a pure state machine called by its platform sixty times a second; the joe version is a small society of actors that nobody calls at all.**

*Thesis: everything the WASM-4 platform does by calling you, the 6564 does by messaging you — and every discipline the Roc code keeps by comment and convention, joe keeps by type.*

---

## 1. The mapping

| WASM-4 / Roc | 6564 / joe |
|---|---|
| platform calls `update!` at 60fps | display device completion — `PresentDone` *is* the frame clock |
| `Model : [TitleScreen, Game, GameOver]` tag union | three actor kinds; the tag is *which actor is alive* |
| `match model { ... }` dispatch | the Cabinet's serve loop; transitions are messages |
| `W4.get_gamepad!()` (poll) | pad device pushes `Pad{buttons}`; the actor latches |
| `W4.tone!(...)` | `send apu, Tone{...}` — fire-and-forget, as sound should be |
| framebuffer + `get_pixel!` peek | a region the actor owns between completions |
| "must be run before drawing the player" (a comment) | granted-region type-state (a compile error) |
| `save_to_disk!` (1KB blob, hand-packed offsets) | the substrate peripheral; struple keys `("rocci", "hs")` |
| `List(Pipe)` + append/filter loops | SoA vectors + a liveness bitset; three expressions |
| sprite constants in the source file | const byte arrays in shared read-only code pages (§11) |
| `crash "animation cell out of bounds"` | an honest fault; the Cabinet inserts another coin |

## 2. The frame clock is a completion

WASM-4 calls you. Nobody calls a 6564 actor — so where does 60Hz come from? Not from an `after` timer. From **backpressure**:

```joe
send display, Present{grant frame}     // frame is now hardware-owned
...
case PresentDone(_):                   // vblank: the frame is ours again
```

You cannot draw faster than the display returns your region, and you cannot miss the beat without the watchdog noticing. The completion is the clock, the grant is the pacing, and the double-buffer upgrade is just two regions alternating grants. This is how real display hardware has always worked; the language finally admits it.

## 3. Screens are a relay, rooted at the Cabinet

First real finding of the exercise. The obvious translation — Game spawns GameOver and halts — **dangles the supervision tree**: exit links point at the spawner, and a dead Game can't read its successor's obituary. So transitions route *through the root*:

```joe
actor Cabinet(display addr, pad addr, apu addr, disk addr) {
    spawn Title(display, pad, apu, disk, 0)

    serve {
        case Next(n) where n.screen == GAME:
            spawn Game(display, pad, apu, disk, n.t)
        case Next(n) where n.screen == OVER:
            spawn GameOver(display, pad, apu, disk, n.t, n.score)
        case Next(n) where n.screen == TITLE:
            spawn Title(display, pad, apu, disk, n.t)

        case exit(_, ok):
            // a screen that announced its successor and left politely

        case exit(w, crash(_)):
            spawn Title(display, pad, apu, disk, 0)
            // any bug in any screen = insert coin.
            // flappy bird with fault tolerance: it cannot wedge, only restart.
    }
}
```

Roc's tag union survives intact — it just became *which child is alive*. And the crash case is the joke that's also true: supervision turns every bug into a game-over screen.

## 4. The Game actor

```joe
actor Game(display addr, pad addr, apu addr, disk addr, t0 u64) {
    var frame region [6400]u8          // 160×160 @ 2bpp

    var t u64 = t0
    var y f32 = 40.0
    var vy f32 = -2.2
    var buttons u8 = 0
    var flap_held bool = true          // Roc's last_flap: True — swallow the starting click

    var rng u64 = mix(t0)              // in-core PRNG; deterministic, replayable

    // pipes: SoA + liveness — Roc's List(Pipe) as lanes
    var pipe_x  [4]i32
    var pipe_gap [4]i32
    var pipes bitset = bitset(4)
    var last_pipe u64 = t0

    var score u8 = 0
    var anim Anim = flap_anim(t0)

    send apu, Tone{FLAP_TONE}
    send display, Present{grant frame}          // the clock starts here

    serve {
        case Pad(p):
            buttons = p.buttons                  // latch; edges belong to frame time

        case PresentDone(_):
            t += 1
            let flap = (buttons & (BTN1 | UP)) != 0

            if !flap_held && flap && flap_allowed(t, anim) {
                send apu, Tone{FLAP_TONE}
                vy = -2.2
                anim = restart(anim)
            } else {
                vy += 0.12                       // y = -a/2·t² + vt, same napkin
                anim = step(t, anim)
            }
            flap_held = flap
            y += vy

            // ---- world update: Roc's four update/filter loops, three expressions
            pipe_x = pipe_x - 1                          // element-wise (A1.4)
            pipes &= (pipe_x >= -20)                     // compare → mask; retire off-screen
            let gained = (pipes & (pipe_x == PLAYER_X - 2)).count()
            score = sat_add(score, gained)
            if gained > 0 { send apu, Tone{POINT_TONE} }

            if t - last_pipe > 90 {
                let k = pipes.missing().first()          // a free lane
                pipe_x[k] = 160
                pipe_gap[k] = rand_below(rng, 16) * 5 + 10
                pipes[k] = true
                last_pipe = t
            }

            // ---- render: every extent below is a compile-time constant,
            // so the A1.3 checker computes this bound; the number is its, not mine
            bounded 38_000 {
                clear(frame)
                draw_pipes(frame, pipe_x, pipe_gap, pipes)
                draw_ground(frame, ground_x(t))
                draw_plants(frame, t)
            }

            // ---- collision: pixel-peek against OUR OWN region, world drawn,
            // player not yet. The Roc original enforces this ordering with a
            // comment ("must be run before drawing the player"). Here the
            // ordering is structural: after the grant below, `frame` is
            // inaccessible — peeking late is not a bug you can write.
            if hit(frame, y_px(y), anim.index) || y >= 134.0 {
                send apu, Tone{DEATH_TONE}
                send boss, Next{OVER, t, score}
                halt ok                          // the bird dies; the actor dies with it
            }

            draw_anim(frame, anim, PLAYER_X, y_px(y))
            draw_score(frame, score)
            send display, Present{grant frame}   // and the clock ticks again
    }
}
```

Things to notice:

- **The SoA pipes are the item-5 workload in miniature.** `update_pipes` (a loop, an append, a bounds filter) and the scoring `count_if` became four vector expressions and a popcount. Plants (15 lanes) go the same way. This little game is a legitimate motivating benchmark for the Tier-1 vector surface — the A1.4 syntax has been waiting for silicon; here's a program waiting for the syntax.
- **The frame has a provable worst case.** Every sprite is a compile-time constant size, the clear is a constant extent, the lane count is 4. The bound checker can price the *entire render* from the ISA table — this game can be certified to never miss vblank by surprise. Arithmetic lies die at compile time; flappy bird has no data lies to tell.
- **Replay is total.** The PRNG is in-core state, the only nondeterminism is input, and input is messages. Record the `Pad` trace and the whole game replays bit-exact under scorch — TAS support as a corollary of the determinism bar.

## 5. Game over, and the substrate cameo

```joe
actor GameOver(display addr, pad addr, apu addr, disk addr, t0 u64, score u8) {
    var frame region [6400]u8
    var key buf [16]u8
    var hs u8 = 0
    var t u64 = t0
    // ... y/vy for the falling bird, anims ...

    pack key, ("rocci", "hs")
    send disk, Get{key}                          // Amendment 2, reporting for duty

    serve {
        case Item(i) where i.key is ("rocci", "hs", ..):
            hs = decode_u8(i.val)
            if score > hs {
                hs = score
                send disk, Put{key, encode_u8(hs)}   // idempotent; no ack protocol
            }

        case PresentDone(_):
            t += 1
            // draw the fall, the panel, HS:, the sparkle anim if new...
            send display, Present{grant frame}

        case Pad(p) where (p.buttons & (BTN2 | RIGHT)) != 0:
            send boss, Next{TITLE, t, 0}
            halt ok
    }
}
```

The Roc original hand-packs a 2-byte disk blob and comments about which byte is which. Here the high score is a **named key in the substrate peripheral** — the same radix engine behind the same contract — and if the game never hears the `Item` back before the player restarts, the store is still consistent, because Put is idempotent and *choosing what to make reliable is the protocol design*. A flappy bird high score does not deserve two-phase commit, and now that's a one-line decision instead of an accident.

## 6. What the exercise found (the actual point)

1. **Transitions must route through the supervisor.** Spawn-and-halt relays dangle exit links. "Screens announce their successor to the root" is the idiom, and it probably wants a line in the joe style guide.
2. **joe wants plain record types.** Roc's `Animation : { last_updated, index, cells, state }` has no v1 home — messages are the only aggregates. A `struct`/record declaration for near-page state (no pointers, fixed layout, just named offsets) is the smallest missing convenience, and a natural A3 rider.
3. **Helper functions want views.** `draw_pipes(frame, ...)` takes the framebuffer — that's a byte view over a region as a parameter, which is exactly A2.2. The amendment lands just in time for its first caller.
4. **The sub-grant question, fourth sighting.** `.from`, view-in-message, range migration — and now *succession*: a dying screen handing its live region to its successor would skip a redraw. Same kernel requirement, fourth costume. The claim check thickens.
5. **Const data pages earn their keep.** Four sprite sheets as read-only byte arrays, shared by every incarnation of every screen actor, blitted with constant extents. §11 was built for this.
6. **The Roc comment became a type.** Pixel-peek-before-draw-player is enforced by region type-state. When a discipline you kept by comment becomes a bug you cannot write, the language is doing its job.

---

*Rocci flapped on a platform that called her. On the 6564 nobody calls — the display writes back, the pad speaks up, the bird decides. Sixty grants a second, and every crash is just another coin.*