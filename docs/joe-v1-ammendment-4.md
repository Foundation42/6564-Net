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

## A4.4 What joe cannot say yet (movement 3)

The machine can hand a region to a successor; joe cannot ask it to. The surface wants to be small — something like `grant frame to heir` in a dying actor's last breath, with the heir receiving an ordinary `case Handoff(h)` — and it needs the loader to know that a spawned successor is a legitimate grantee. That is the next increment, and rocci-bird's Cabinet is its first caller.

## A4.5 What this says about the kernel

Q9 asked whether capability transfer deserves architectural surface. Movement 2's answer is that it already had it: a PTT entry was always a capability, a region descriptor was always a capability, and "transfer" is just the operation that was missing from the table. The kernel's paper trail is not a new subsystem — it is the completion queue, which has been auditing everything else since v0.1.

What remains genuinely undesigned is *policy*: who may mint, who may revoke a capability they did not grant, and what a revocation means to a chain of derived rights. Those are kernel questions, and they are now the only ones left in the costume.

---

*A compiler that says "trust me" has said nothing. A capability that says "here is what I am, here is what you may do, and here is who gave it to me" has said everything.*
