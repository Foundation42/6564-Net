# joe — v1 Amendment 4: Rights on Capabilities

**Status: movements 1 and 2 implemented (2026-07-19). Christian's sketch, priced by the machine. Movement 3 — the joe surface for succession — is open.**

*Verdict in one line: the rights word is two fields that check differently, and capability transfer is what a kernel IS, not a feature it needs.*

The costume count was the tell. `.from` (a reply capability the sender cannot name), region sub-grants, key-range migration, and — once Amendment 3 shipped a dialect line the compiler held alone — device flavours. Four sightings of one mechanism is not coincidence; it is the mechanism knocking.

---

## A4.1 The load-bearing observation: two fields, two disciplines

Everything called "flavour" and everything Q9 calls "transfer" divides cleanly, and conflating them builds the wrong thing:

| field | what it says | check | attenuable |
|---|---|---|---|
| **dialect** | what the endpoint **is** — `raw` sink, `msg` actor, `ask` device | **equality**, at accept | **no** |
| **verbs** | what the holder **may do** — read, write, send, grant | **subset**, at accept | yes |

*Dialect* is descriptive: exactly one value per endpoint (a console is never sometimes-framed), and a *weakened* dialect is nonsense. *Verbs* are permissive: a set, narrowed on transfer by whatever the grantor withholds. Attenuation is meaningful only in the second column, which is precisely why the two must not share one.

**`any` is UNSET, not top.** A dialect field may read `any`, meaning no declaration was made: a loader-era entry wired before the field existed. Its checks are **skipped, not satisfied**. This is not a two-level lattice, and replacing `any` is therefore not attenuation — there is nothing there to attenuate. Two consequences, both load-bearing for movement 2: **a derived capability may never carry `any`** (minting is exactly when the grantor must say what it is for), and `any` is scaffolding that transfer cannot propagate — it ends where the static wiring ends.

## A4.2 Movement 1: where the check lives

The SQE's reserved hint word carries the sender's **claim** of what its payload is: `pack`-built claims `msg`, `append`-built claims `raw`, an `->`-declared request claims `ask`. The RBC compares claim against the target entry's dialect in the same breath it compares tokens; mismatch is a capability-family reject, both ends told, no bytes moved.

A **register send (`TXR`) claims `msg` by construction** — you cannot print a register, and an ask needs a window word it hasn't got. The busiest path in the machine therefore carries its dialect structurally, in no bits at all, which is why Armstrong's ring did not move.

joe's surface: **nothing.** Dialect is inferred from the system block, where the wiring already lives — `Console()` is raw, `->`-declared contracts are ask, actors are msg — and flows through parameters. The compiler's check is the *early copy* of the machine's (§2.3), never a substitute: a hand-written program that lies is rejected by silicon.

**The safety argument, not the hygiene one.** A `msg` image arriving at an `ask` device would have the device read a message tag as a reply window *in its own PTT space* — a wild capability synthesized from a number. The equality check makes that unrepresentable.

**Evidence, pre-registered before implementation:**

| claim | result |
|---|---|
| null cost, falsifiable | frozen tables **byte-identical**: 2820 B / 171,532 instr / 479,275 cy / 13,281 switches |
| rejected programs | framed message at a raw sink; raw bytes at an actor; plain message at an asking device — all compile errors |
| **the bypass** | a hand-written `.asm` stamping a `msg` claim at a `raw` endpoint is rejected **by the RBC**, console unheard |

The third is the thesis: the right lives in the capability, not in the language.

## A4.3 Movement 2: succession

`SqOp.grant` hands a capability to another context. `buf` names the source descriptor slot, `len` carries the verbs the grantee receives, `target` is the window of whoever inherits.

- **Hardware picks the grantee's slot.** A grantor that had to know the grantee's table layout would be reaching into it.
- **Fresh token, minted by the RBC.** The old one cannot open the new door.
- **The grantor surrenders its copy** (token zeroed): succession, not sharing. Sub-granting — the copy-with-attenuation case — is the same mechanism minus the surrender, and is left for the workload that needs it.
- **Verbs narrow, never widen**: `grantee ⊆ grantor`, and a holder without the `grant` verb cannot delegate at all — so a chain is ended by whoever withholds it.
- **Provenance is a delivery.** The grant record carries base, extent, token, the new slot, and *which core, which context, which incarnation, from which of their slots*. It arrives as an ordinary message because a capability moving **is** a message, and everything auditable in this machine is already a record someone can read.

Refusals share one rule — *what you do not hold, you cannot pass on*: a revoked token, a region already granted out to silicon (OWNED), and a holder never given the right to delegate.

**The tripwire stayed silent, and the reason is a finding.** Movement 1's rule was: if the transfer verb ever wants to modify a dialect, the field boundary was drawn wrong. It never wanted to — because **a region carries no dialect to copy.** Dialect is an *endpoint* property; a span of memory is not an endpoint. So the two fields are not parallel across capability kinds: **verbs are universal, dialect belongs to things you send to.** That asymmetry was not designed; it fell out of implementing both, and it is the strongest evidence so far that the split is real rather than tidy.

**Why it is true, and therefore what it predicts.** Dialect is a property of the **object** — what the thing at the far end will do with arriving bytes; it presupposes an *interpreter*. Verbs are a property of the **relationship** — what this holder may do with what it holds. A region has a base and an extent and no interpreter, so it has no dialect to have. That makes the rule predictive rather than descriptive: **any future capability kind gets verbs automatically, and gets a dialect if and only if something on the far end interprets.**

The prediction is pre-registered here, on a capability kind that does not exist yet. Amendment 2's D1 note (key-as-location) will eventually make a *key range* a capability. A range you merely **own** is a region — verbs, no dialect, nothing interprets. A range you can **send to** — the fabric resolving a coordinate from the key prefix — is an endpoint, and it should acquire a dialect at that exact moment (`msg`, presumably, since the store speaks struple messages), not before. If D1's work finds a range capability wanting a dialect precisely when routing lands, the asymmetry is confirmed on a kind that was not in evidence when the rule was found. If it wants one earlier, or never wants one at all, this section is wrong and should say so.

## A4.4 Movement 3: succession is probate, not bequest

The obvious shape — a dying screen grants directly to its heir — has an ordering hole that no mechanism can close: **the heir does not exist yet.** The Cabinet spawns it only after hearing the death, and a grantor cannot grant after halting. Bequest would need grant-to-a-future-incarnation, or a loader clairvoyant about who counts as an heir.

The house answer needs neither, because the rocci ledger already found it for transitions: **route through the supervisor.** A screen grants its frame *to the Cabinet* in its last breath and halts; the Cabinet hears the exit, spawns the successor, and re-grants. Two records in the paper trail instead of one — which for an estate is not overhead, it is the point. **Probate is the paper trail.**

Legitimacy comes free: the only grantee an actor ever needs to name is its supervisor, the exit link already establishes that relationship, and the supervisor's authority to redistribute is nothing more than the `grant` verb it holds. *The supervisor is the executor of the estate*, which sits exactly beside *death is a message*.

**The decision this forces, made on purpose: who owns a frame while a screen is drawing on it?**

The honest edge is dying while `OWNED`. A screen that crashes mid-`Present` has its region granted out to the display: the refusal rule correctly blocks any last-breath grant, and the release completion arrives incarnation-stamped at a corpse. The descriptor survives in the near page and hardware clears `OWNED` before the record lands, so the region *is* reclaimable — but by whom, and how does the executor learn it is safe? That is the succession analogue of lame-duck: **an estate is not distributable until silicon has finished with it.**

Two ways to answer, and this amendment picks the second:

1. *Screens own their frames.* The Cabinet must then learn when a dead child's grant has drained — a wait-for-silicon step in the executor, and a new thing for a supervisor to know about.
2. **Screens receive, never own.** The Cabinet holds the frame capability from the start and lends it to each screen; a screen's death returns nothing, because it was never the owner. The `OWNED` race dissolves: whatever the display still has, it has against the Cabinet's capability, and the Cabinet is not dead.

The second is chosen because it removes a state rather than handling one, and because it matches what a cabinet *is* — the machine outlives the game. The cost is honest and worth stating: a screen can no longer be given a frame it may pass on, so a future workload that genuinely wants transitive lending will have to revisit this. It is a choice, not an accident.

joe's surface, then, is two statements and one case: `grant frame to boss` in a last breath, the loader staging every spawned child a capability to its spawner (the exit link's twin, and free for the same reason), and `case handoff(h)` adopting a granted region into the heir's own descriptor slot.

## A4.5 Movement 3, the other half: signing for the estate

The estate arrived in the first half and could not be named. `case handoff(h)` binds it; `adopt h as frame` signs for it. What the increment actually cost, and what it found:

**Adoption is a copy, not a reconstruction.** Hardware picks the grantee's descriptor slot — a grantor that had to know the heir's table layout would be reaching into it — so adoption moves that descriptor into the slot the heir's own `frame` names, and clears the source. Crucially it copies the *whole* descriptor rather than rebuilding one from the record's fields, because the verbs are in it. Rebuilding would mean re-deriving an attenuation the heir does not get to choose, which is precisely how a permission gets quietly widened. **The only honest way to preserve a field you do not interpret is to copy it.**

**The language was already built for this and nobody knew.** A joe `region` compiles to two things: a near-page pointer cell that indexing dereferences (`LDA ($ptr),Y`) and a descriptor slot that silicon reads. Adoption writes the inherited base into both — five stores — and `frame[i]` addresses the inherited memory for free. The indirection was there for array layout; it turned out to be the mechanism that lets a region live somewhere other than where its holder was compiled to expect. **A design is well-factored when the feature you did not plan costs five stores.**

**`onward` — attenuation made visible.** Movement 3's first half lent one level deep by hardcoding `read|write`. The second half discovered why that cannot be the only option: *an executor that cannot distribute the estate is not an executor*. Rather than infer the delegation right from the grantee's identity — conferring it on `boss` because probate implies it — the grantor states it: `grant frame to boss onward`. The chain still ends by default, and now it ends **visibly**, at a word somebody chose not to write. The alternative would have made a security property depend on who you are talking to rather than what you said.

**What the machine refused, twice.** Two defects surfaced, both invisible until the second half needed them:

- **A guard in the wrong half of the word.** The grant record was `$6772_0001`: the architected mark where nothing masks, and tag **1** — every program's first message — where every tag test does. Heirs handled their own inheritance as an ordinary delivery, silently, reading a descriptor slot as a message field. Worse, joe elides the tag test entirely for a sole unguarded case, on the stated precondition that *the wire is closed: every sender compiles from this same source.* A grant breaks exactly that precondition, because the RBC becomes a sender no `message` declaration describes. The fix is both halves: the mark moved into the low 16 bits with a kind byte above it, and the elision now checks whether the program grants at all. **An optimisation's precondition is a claim, and claims go stale when the system grows a new kind of sender.**
- **A capability that meant something else at the destination.** RAM is per-core; a region's base is a core-local address. The RBC was granting across cores, handing the grantee a flawless capability — right length, correct verbs, fresh token — over memory it never named. Nothing malformed, so nothing complained; the heir simply read a different core's bytes. Movement 2 shipped this and its test could not see it, because both parties sat on core 0. Regions now may not leave their memory domain (§6.2). So the rights word's two disciplines have a third companion that is neither: verbs attenuate by subset, dialects compare by equality, and **domains must simply match** — the same structure the dialect finding predicted, with memory as the domain.

**The honest gap.** Probate now runs end to end and the suite proves a three-holder chain of custody — a screen's framebuffer reaching an archive through the Cabinet, the same span of memory at every hop, read correctly by an actor two hops downstream of the one that wrote it. What it does *not* yet do is the thing A4.4 describes: re-grant to a **successor**. `spawn` gives a supervisor no name for its child — obituaries flow up, but nothing addresses down — so the Cabinet can pass an estate to any peer it can name and not to the screen it just started. That is a missing capability in *supervision*, not in transfer, and it is the next increment: **a supervisor that can bury a child but not write to one is only half a parent.** (Closed in A4.7.)

## A4.6 What this says about the kernel

Q9 asked whether capability transfer deserves architectural surface. Movement 2's answer is that it already had it: a PTT entry was always a capability, a region descriptor was always a capability, and "transfer" is just the operation that was missing from the table. The kernel's paper trail is not a new subsystem — it is the completion queue, which has been auditing everything else since v0.1.

What remains genuinely undesigned is *policy*: who may mint, who may revoke a capability they did not grant, and what a revocation means to a chain of derived rights. Those are kernel questions, and they are now the only ones left in the costume.

## A4.7 The other half of the parent: a supervisor names its child

A4.5 left probate able to flow up (a screen to its Cabinet) and across (the Cabinet to a peer it was wired to), but never *down*. The Cabinet could bury a screen and not write to one, because `spawn` gave it no name for the child it started. The exit link was a one-way street: obituaries addressed the supervisor, and nothing addressed the child.

The surface is one word. `spawn Screen(1) as screen` binds `screen` to a capability aimed at the child's RX ring — **the exit link's twin, pointed the other way.** The loader mints it exactly as it mints the exit link, and for the same reason it is legitimate: the supervisor already owns the relationship, so pointing a capability along it invents no new authority. With the name in hand, `grant frame to screen` and `send screen, …` both work, because they resolve their target through the same table every other capability does. The child, in turn, can now `send boss, …` as well as `grant … to boss` — the conversational twin of the link it already had. A whole parent: it can bury a child and write to one.

**What the estate's direction taught us about time.** Granting *down* is not the mirror image of granting up, because of *when* the grantee exists. When a screen grants up, the Cabinet is long since alive and its descriptor table already laid out; the grant lands in a free slot and waits to be adopted. When the Cabinet grants down, the child may not have run yet — and a grant *claims a descriptor slot in the grantee's table*. Hand an estate to a child still in its constructor and the slot is chosen before the child has staged its own regions; the child's init then writes over the inheritance, and `adopt` copies back an empty descriptor. Nothing is malformed — the same failure signature as the two defects in A4.5. The discipline that dissolves it is the one rocci already implies: **a supervisor lends to a child that is already running.** The screen announces itself to `boss` once its own regions are staged; the Cabinet grants in reply. The request is not ceremony — it is the child telling its parent that the estate now has somewhere safe to land. *You cannot inherit a house while you are still being built.*

This is exactly the shape A4.4 chose for rocci and could not yet write: the Cabinet holds the frame for the machine's whole life and lends it to each screen. The suite now proves it — a supervisor spawns an heir, names it, and lends it a marked estate that the heir reads back through a name of its own. What remains for rocci is the *dynamic* spawn: naming a child started inside a `serve` handler, not the actor body, so the Cabinet can hand the frame to a screen it starts on a transition rather than at boot. Same name, later in time — A4.8.

## A4.8 The same name, later in time: the dynamic spawn

A4.7 named children, but only at boot — `spawn` still had to live in the actor body. rocci's Cabinet does not work that way: it starts `Game` when the title screen is dismissed, `GameOver` when the bird dies, `Title` again when the player restarts. Each transition spawns the next screen from *inside a `serve` handler*, and the amendment's last increment is to let it.

The change is almost entirely a matter of *bookkeeping*, and that turns out to be the interesting part. A `SPWN` reads a spawn record — context id, entry, stack, argument — that the loader staged at a fixed near-page offset; the compiler assigns each spawn its record slot. When every spawn lived in the body, the slot could be assigned by counting spawns in body order, because that is also the order they were emitted. A spawn in a handler breaks that coincidence: the emitter reaches handlers through region dispatch, then the case ladder, then the timer body — a sequence no single walk over the source reproduces. So the record index is now fixed by the spawn's *identity* — the address of its statement — assigned in one canonical walk and looked up wherever a `SPWN` is emitted. Emission order stops mattering. **When a thing can appear in more than one place, stop numbering it by where you happen to find it.**

Everything downstream then falls out for free, because the loader already reserved a context per spawn *site* and pre-wired all four of its links — exit, watchdog, `boss`, and the A4.7 capability — to that fixed context. A handler spawn is a site like any other; the loader does not care that its `SPWN` fires late. Which answers the question the increment really turns on: what happens when the same site spawns again, transition after transition? `SPWN` reuses the one context the loader reserved and bumps its generation — fresh registers, same near page. **The RX ring lives in the near page a restart does not move, so the capability aimed at it survives every incarnation the site starts.** The parent addresses `screen` once and reaches whichever screen is currently alive in that slot; a stale continuation from the previous life carries the old generation and is skipped at dispatch. The suite fires one site twice and sends down the same capability to both lives; each hears the message and reports back, and the second report could not arrive if the second send had gone nowhere.

Two properties make this safe rather than merely working. A screen halts *synchronously*, inside its own burst, so it is always dead before the Cabinet processes the message that triggers the next spawn — the successor never restarts a living context. And the ready-handshake from A4.7 is not a one-time boot step but a per-life one: each incarnation re-runs its init, re-claims its own descriptor slots, and re-announces itself, because a restart resets the ring's contents even though it preserves the ring. The capability is stable across lives; the estate's landing slot is claimed afresh each life. *The house keeps its address while its tenants come and go, and every new tenant still has to unpack before you hand them the keys.*

With this, the Cabinet is expressible end to end: a boot screen, transitions that spawn the next, a frame lent down each life and returned by death, and probate that reaches a real successor. rocci-bird is no longer waiting on the language.

## A4.9 Lending the world: capability-passing spawn

A4.7 and A4.8 gave a supervisor a name for its child and let it spawn one mid-serve, but the child was born into an empty room. `spawn` took only literal numbers, so a Cabinet could start a `Game` and could not hand it the display it must draw on, the pad it must read, or the APU it must sound. The bird ran only as a top-level actor wired by the system block; the Cabinet that *is* the machine could supervise a screen it could not equip. This closes that: `spawn Game(display, pad, apu)` lends the child the very capabilities the supervisor holds.

The mechanism is substitution, and that it is *only* substitution is the point. A spawn argument that is a name refers to one of the supervisor's own parameters — the one thing a supervisor is entitled to lend, because it already holds it — and the child inherits the supervisor's *binding* for it: the same device coordinate, the same peer context, resolved and staged into the child's near page exactly as the loader stages any instance's arguments. No capability is minted that the supervisor did not already have; nothing new is trusted. **A supervisor can lend only what it holds, and lending is the whole of it** — the child gets its own window onto the shared device, and the amendment's paper-trail principle holds without a new record, because a spawn argument is just a name for a capability that already existed.

That the child is spawned *dynamically* (A4.8) changes nothing: the loader reserved the child's context and pre-stages its inherited bindings once, so every incarnation the site starts wakes already holding the world. The Cabinet in `cabinet.joe` proves it — three lives, each `spawn Game(display, pad, apu)` lending the device row, each bird presenting frames and playing tones through capabilities it was handed rather than born with, and death inserting the next coin. That a *spawned* child presents to the display at all is the proof: without this it could not reach a device it was given.

One honest edge remains, and it is not in spawn. A device with a single reply window — the pad — admits one subscriber, so across a game's successive lives only the first bird hears the pad; the rest fall in silence. That is the row's one-asker rule (§7.8), not a limit of lending, and the fix is a re-subscribing pad, not a change to how capabilities pass. Probate hands an estate to a successor; A4.9 hands a supervisor's children the world it lives in; what is left is to let more than one of them listen at once.

---

*A compiler that says "trust me" has said nothing. A capability that says "here is what I am, here is what you may do, and here is who gave it to me" has said everything.*
