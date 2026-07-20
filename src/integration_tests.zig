//! End-to-end tests: assemble real 6564 programs and run them on the
//! simulated machine, exercising the queue pairs, the scheduler, and —
//! critically — the failure semantics of §6.
//!
//! RAM layout used throughout (per core):
//!   $1000 code (ctx0)      $1400 code (ctx1)     $2000 CQ ring (ctx1)
//!   $2100 RX ring (ctx1)   $2200 landing buffer  $2280 results
//!   $2300 CQ ring (ctx0)   $2400 SQ ring (ctx0)  $2500 tx payload
//!   $3000/$3800 stacks

const std = @import("std");
const testing = std.testing;
const isa = @import("isa.zig");
const ring = @import("ring.zig");
const mesh = @import("mesh.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");
const joe = @import("joe.zig");

const Machine = machine.Machine;

fn assembleInto(m: *Machine, core: u16, src: []const u8) !void {
    var diag = asm6564.Diagnostic{};
    var out = asm6564.assemble(testing.allocator, src, &diag) catch |err| {
        std.debug.print("asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer out.deinit();
    m.load(core, out.origin, out.code);
}

/// Standard rings for a receiving context: CQ at cq_base (cap 8), RX ring at
/// rx_base (cap 1 so its entry address is constant), companion CQ = slot 1.
fn wireReceiver(m: *Machine, core: u16, ctx: u8, cq_base: u64, rx_base: u64, token: u64) void {
    m.setRing(core, ctx, ring.slot_cq, .{
        .base = cq_base,
        .cap_log2 = 3,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(core, ctx, ring.slot_rx, .{
        .base = rx_base,
        .cap_log2 = 0,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = token,
    });
}

fn wireSender(m: *Machine, core: u16, ctx: u8, cq_base: u64, sq_base: u64) void {
    m.setRing(core, ctx, ring.slot_cq, .{
        .base = cq_base,
        .cap_log2 = 3,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(core, ctx, ring.slot_sq, .{
        .base = sq_base,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
}

// The receiver's little actor: post a landing buffer, park on the CQ, and on
// the first clean delivery record what landed, then halt.
const receiver_src =
    \\        .org $1400
    \\        ; stage the RX landing-buffer entry (RX ring cap = 1, so the
    \\        ; entry address is constant: the ring base)
    \\        LDA ##$2200
    \\        STA !$2100          ; word0: buffer address
    \\        LDA #64
    \\        STA !$2108          ; word1: capacity
    \\        LDA #0
    \\        STA !$2110          ; word2: filled (hw)
    \\        LDA #$77
    \\        STA !$2118          ; word3: cookie
    \\serve:  RECV 2              ; doorbell: grant the RBC landing space
    \\        LSTN 1              ; park until the CQ has news
    \\        CQPOP 1
    \\        BEQ serve           ; spurious wake: nothing there
    \\        TAY                 ; keep completion word0 in Y
    \\        STA !$2280          ; record completion word0
    \\        STX !$2288          ; record cookie
    \\        ; status = (word0 >> 8) & $FF — eight one-bit shifts
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        AND #$FF
    \\        CMP #0
    \\        BNE serve           ; not a clean delivery: keep serving
    \\        LDA !$2200          ; fetch what landed
    \\        STA !$2290
    \\        HLT
;

test "phase 1: TXR datagram between contexts on one core" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x8000,
    });
    defer m.deinit();

    // ctx0 → PTT slot 0 → (core 0, ctx 1, RX slot 2), token 0xBEEF.
    m.setPtt(0, 0, .{
        .prefix_hi = 0xfd65_6400_0000_0000,
        .prefix_lo = ring.PttEntry.loFrom(0, 1, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0xBEEF,
    });
    wireSender(&m, 0, 0, 0x2300, 0x2400);
    wireReceiver(&m, 0, 1, 0x2000, 0x2100, 0xBEEF);

    const sender_src =
        \\        .org $1000
        \\        LDA ##$FF00_0000_0000_0000  ; window ptr: PTT slot 0, offset 0
        \\        STA $800                    ; park the pointer in near scratch
        \\        LDA #99
        \\        TXR ($800),A                ; single-register datagram
        \\        LSTN 1                      ; park until the ack completion
        \\        CQPOP 1
        \\        STA !$2298                  ; record our completion word0
        \\        HLT
    ;
    try assembleInto(&m, 0, sender_src);
    try assembleInto(&m, 0, receiver_src);
    // Receiver first: it must post its landing buffer before the TXR fires,
    // or the datagram honestly rejects with no_buffer (an actor race).
    try m.spawn(0, 1, 0x1400, 0x3800, 0);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    try testing.expectEqual(machine.StopReason.all_halted, try m.run());

    const ram = m.cores[0].ram;
    const word = struct {
        fn at(r: []u8, addr: u64) u64 {
            return std.mem.readInt(u64, r[addr - machine.ram_base ..][0..8], .little);
        }
    }.at;
    // The payload landed.
    try testing.expectEqual(@as(u64, 99), word(ram, 0x2290));
    // Receiver's completion: tag=deliver, status=ok, 8 bytes, cookie 0x77.
    const rc = ring.Completion.fromWords(word(ram, 0x2280), word(ram, 0x2288));
    try testing.expectEqual(ring.Tag.deliver, rc.tag);
    try testing.expectEqual(ring.Status.ok, rc.status);
    try testing.expectEqual(@as(u32, 8), rc.byte_count);
    try testing.expectEqual(@as(u64, 0x77), rc.cookie);
    // Sender's completion: tag=txr, status=ok.
    const sc = ring.Completion.fromWords(word(ram, 0x2298), 0);
    try testing.expectEqual(ring.Tag.txr, sc.tag);
    try testing.expectEqual(ring.Status.ok, sc.status);
    try testing.expectEqual(@as(u64, 1), m.stats.delivered);
}

test "capability token mismatch rejects at both ends, no data moves" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x8000,
    });
    defer m.deinit();

    // Sender's PTT holds a stale token: the receiver's ring wants 0x2222.
    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(0, 1, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0x1111,
    });
    wireSender(&m, 0, 0, 0x2300, 0x2400);
    wireReceiver(&m, 0, 1, 0x2000, 0x2100, 0x2222);

    const sender_src =
        \\        .org $1000
        \\        LDA ##$FF00_0000_0000_0000
        \\        STA $800
        \\        LDA #99
        \\        TXR ($800),A
        \\        LSTN 1
        \\        CQPOP 1
        \\        STA !$2298
        \\        HLT
    ;
    // Victim posts a buffer, parks, records whatever completion shows up,
    // and halts — it should witness the rejected attempt (§6.4).
    const victim_src =
        \\        .org $1400
        \\        LDA ##$2200
        \\        STA !$2100
        \\        LDA #64
        \\        STA !$2108
        \\        LDA #0
        \\        STA !$2110
        \\        LDA #$77
        \\        STA !$2118
        \\        RECV 2
        \\        LSTN 1
        \\        CQPOP 1
        \\        STA !$2280
        \\        HLT
    ;
    try assembleInto(&m, 0, sender_src);
    try assembleInto(&m, 0, victim_src);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try m.spawn(0, 1, 0x1400, 0x3800, 0);

    try testing.expectEqual(machine.StopReason.all_halted, try m.run());

    const ram = m.cores[0].ram;
    const at = struct {
        fn f(r: []u8, addr: u64) u64 {
            return std.mem.readInt(u64, r[addr - machine.ram_base ..][0..8], .little);
        }
    }.f;
    // No byte moved into the landing buffer.
    try testing.expectEqual(@as(u64, 0), at(ram, 0x2200));
    // Both ends saw the reject.
    const victim = ring.Completion.fromWords(at(ram, 0x2280), 0);
    try testing.expectEqual(ring.Status.reject_capability, victim.status);
    const sender = ring.Completion.fromWords(at(ram, 0x2298), 0);
    try testing.expectEqual(ring.Status.reject_capability, sender.status);
    try testing.expectEqual(@as(u64, 1), m.stats.rejects);
    try testing.expectEqual(@as(u64, 0), m.stats.delivered);
}

test "phase 2: SEND across a lossy link, retransmit from CQ feedback" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 2,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
        .seed = 0x5EED,
        .link = .{
            .base_latency = 100,
            .jitter = 60,
            .loss_ppm4k = 1024, // 25% loss, datagrams AND acks
            .dup_ppm4k = 256, // ~6% duplication
            .send_timeout = 1500,
        },
    });
    defer m.deinit();

    // Core 0 ctx 0 sends to core 1 ctx 0's RX ring.
    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(1, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0xCAFE,
    });
    wireSender(&m, 0, 0, 0x2300, 0x2400);
    wireReceiver(&m, 1, 0, 0x2000, 0x2100, 0xCAFE);

    // Sender: stage one SQ entry (SQ cap = 1 → constant address), then
    // SEND/park/pop in a loop until the fabric tells us it arrived.
    // Status 0 (ok) ends the loop; reject_no_buffer (3) means the receiver
    // already got a copy and moved on — also success at this layer.
    const sender_src =
        \\        .org $1000
        \\        ; the message itself
        \\        LDA ##$6564_6564_6564_6564
        \\        STA !$2500
        \\        ; stage the transmit descriptor (§6.2)
        \\        LDA #1
        \\        STA !$2400                  ; word0: op = send
        \\        LDA ##$FF00_0000_0000_0000
        \\        STA !$2408                  ; word1: target (PTT slot 0)
        \\        LDA ##$2500
        \\        STA !$2410                  ; word2: buffer
        \\        LDA ##$42_0000_0008
        \\        STA !$2418                  ; word3: len 8 | cookie $42
        \\retry:  SEND 0
        \\        LSTN 1
        \\        CQPOP 1
        \\        BEQ retry                   ; spurious wake
        \\        STA !$2298                  ; last completion, for inspection
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        AND #$FF
        \\        CMP #0
        \\        BEQ done                    ; delivered and acknowledged
        \\        CMP #3
        \\        BEQ done                    ; peer stopped listening: it has it
        \\        INC !$22A0                  ; count a retry
        \\        BRA retry
        \\done:   HLT
    ;
    try assembleInto(&m, 0, sender_src);
    try assembleInto(&m, 1, receiver_src);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try m.spawn(1, 0, 0x1400, 0x3800, 0);

    try testing.expectEqual(machine.StopReason.all_halted, try m.run());

    // The message crossed the hostile fabric intact.
    const rram = m.cores[1].ram;
    try testing.expectEqual(
        @as(u64, 0x6564_6564_6564_6564),
        std.mem.readInt(u64, rram[0x2290 - machine.ram_base ..][0..8], .little),
    );
    try testing.expect(m.stats.delivered >= 1);
    try testing.expect(m.stats.sends >= 1);
}

test "phase 2: total loss reports honest timeouts, never blocks the core" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 2,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
        .link = .{ .loss_ppm4k = 4096, .send_timeout = 500 }, // 100% loss
    });
    defer m.deinit();

    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(1, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0,
    });
    wireSender(&m, 0, 0, 0x2300, 0x2400);

    const src =
        \\        .org $1000
        \\        LDA ##$FF00_0000_0000_0000
        \\        STA $800
        \\        LDA #1
        \\        TXR ($800),A
        \\        LSTN 1
        \\        CQPOP 1
        \\        STA !$2298
        \\        HLT
    ;
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    const w0 = std.mem.readInt(u64, m.cores[0].ram[0x2298 - machine.ram_base ..][0..8], .little);
    const c = ring.Completion.fromWords(w0, 0);
    try testing.expectEqual(ring.Status.timeout, c.status);
    try testing.expectEqual(@as(u64, 1), m.stats.timeouts);
    try testing.expectEqual(@as(u64, 1), m.stats.lost);
}

test "CONT and YLD: continuations rotate through the run queue" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();

    const src =
        \\        .org $1000
        \\        CONT other      ; queue a second continuation
        \\        LDA #1
        \\        STA $800
        \\        YLD             ; rotate: 'other' runs next
        \\        BRK             ; never reached: ctx halts in 'other'
        \\other:  LDA $800
        \\        INC
        \\        STA $808
        \\        HLT
    ;
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x2000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());

    const ctx = &m.cores[0].contexts[0];
    try testing.expectEqual(
        @as(u64, 1),
        std.mem.readInt(u64, ctx.near[0x800..][0..8], .little),
    );
    try testing.expectEqual(
        @as(u64, 2),
        std.mem.readInt(u64, ctx.near[0x808..][0..8], .little),
    );
}

test "determinism: identical seeds produce identical runs" {
    var results: [2]machine.Stats = undefined;
    for (&results) |*r| {
        var m = try Machine.init(testing.allocator, .{
            .cores = 2,
            .contexts_per_core = 1,
            .ram_size = 0x8000,
            .seed = 0xD37E12,
            .link = .{ .loss_ppm4k = 1024, .dup_ppm4k = 512, .jitter = 80, .send_timeout = 1200 },
        });
        defer m.deinit();
        m.setPtt(0, 0, .{
            .prefix_lo = ring.PttEntry.loFrom(1, 0, ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0xCAFE,
        });
        wireSender(&m, 0, 0, 0x2300, 0x2400);
        wireReceiver(&m, 1, 0, 0x2000, 0x2100, 0xCAFE);
        const sender_src =
            \\        .org $1000
            \\        LDA ##$ABCD
            \\        STA !$2500
            \\        LDA #1
            \\        STA !$2400
            \\        LDA ##$FF00_0000_0000_0000
            \\        STA !$2408
            \\        LDA ##$2500
            \\        STA !$2410
            \\        LDA ##$7_0000_0008
            \\        STA !$2418
            \\retry:  SEND 0
            \\        LSTN 1
            \\        CQPOP 1
            \\        BEQ retry
            \\        LSR
            \\        LSR
            \\        LSR
            \\        LSR
            \\        LSR
            \\        LSR
            \\        LSR
            \\        LSR
            \\        AND #$FF
            \\        CMP #0
            \\        BEQ done
            \\        CMP #3
            \\        BEQ done
            \\        BRA retry
            \\done:   HLT
        ;
        try assembleInto(&m, 0, sender_src);
        try assembleInto(&m, 1, receiver_src);
        try m.spawn(0, 0, 0x1000, 0x3000, 0);
        try m.spawn(1, 0, 0x1400, 0x3800, 0);
        _ = try m.run();
        r.* = m.stats;
    }
    try testing.expectEqualDeep(results[0], results[1]);
}

// ── CQ overflow: which losses are survivable (§11 q6, promoted) ─────────

test "cq overflow: a lost delivery kills the context; a lost verdict does not" {
    // Two records into a CQ with room for one. The verdict (a send ack)
    // is re-derivable — the peer retries, the timer fires again — so it
    // drops and counts. The delivery exists nowhere else: losing it is
    // the silent-forever failure, so the context dies and its exit link
    // can speak.
    for ([_]ring.Tag{ .send, .deliver }) |second| {
        var m = try Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 1,
            .ram_size = 0x4000,
        });
        defer m.deinit();
        m.setRing(0, 0, ring.slot_cq, .{
            .base = 0x2000,
            .cap_log2 = 0, // one record, and no more
            .entry_size = ring.cq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        m.load(0, 0x1000, &.{0xDB}); // HLT
        try m.spawn(0, 0, 0x1000, 0x3000, 0);
        m.postCompletion(0, 0, ring.slot_cq, .{ .tag = .send, .status = .ok, .byte_count = 0, .cookie = 1 });
        m.postCompletion(0, 0, ring.slot_cq, .{ .tag = second, .status = .ok, .byte_count = 0, .cookie = 2 });
        try testing.expectEqual(@as(u64, 1), m.stats.cq_overflows);
        const ctx = &m.cores[0].contexts[0];
        if (second == .deliver) {
            try testing.expectEqual(machine.Fault.cq_overflow, ctx.fault);
            try testing.expectEqual(machine.CtxState.faulted, ctx.state);
        } else {
            try testing.expectEqual(machine.Fault.none, ctx.fault);
            try testing.expect(ctx.state != .faulted);
        }
    }
}

test "A4 movement 3: probate from joe — the estate reaches the executor" {
    // `grant frame to boss` in a dying actor's last breath. The grantee an
    // actor names is its supervisor, because the exit link already
    // establishes that relationship — no clairvoyance about heirs, and no
    // grant-to-a-future-incarnation.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\message Draw { }
        \\actor Screen(tick u64) {
        \\    var frame region [64]u64
        \\    frame[0] = 6564
        \\    grant frame to boss
        \\    halt ok
        \\}
        \\actor Cabinet() {
        \\    var deaths u64 = 0
        \\    spawn Screen(1) restarts 0 watchdog 0
        \\    serve {
        \\        case exit(w, crash(code)):
        \\            deaths += 1
        \\    }
        \\}
        \\system {
        \\    cab = Cabinet()
        \\}
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    // One capability moved, and the screen is properly dead.
    try testing.expectEqual(@as(u64, 1), o.stats.grants);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab/Screen#0").?.state);
}

test "A4 movement 3: signing for the estate — adopt, and the chain of custody" {
    // Probate end to end. A screen dies having handed its framebuffer to
    // its supervisor `onward`; the Cabinet SIGNS for it (`adopt`), reads
    // the dead actor's memory through a name of its own, and passes it to
    // the Archive. Three holders, one span of memory, never copied.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\actor Screen(tick u64) {
        \\    var frame region [64]u64
        \\    frame[0] = 6564
        \\    grant frame to boss onward
        \\    halt ok
        \\}
        \\actor Archive(name u64) {
        \\    var kept region [64]u64
        \\    var got u64 = 0
        \\    serve {
        \\        case handoff(h):
        \\            adopt h as kept
        \\            got = kept[0]
        \\    }
        \\}
        \\actor Cabinet(arch addr) {
        \\    var frame region [64]u64
        \\    var saw u64 = 0
        \\    spawn Screen(1) restarts 0 watchdog 0
        \\    serve {
        \\        case handoff(h):
        \\            adopt h as frame
        \\            saw = frame[0]
        \\            grant frame to arch
        \\    }
        \\}
        \\system { arch = Archive(1) on 0 cab = Cabinet(arch) on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    // Two successions, and the value survives both: what the Archive reads
    // was written by an actor that died two hops ago.
    try testing.expectEqual(@as(u64, 2), o.stats.grants);
    try testing.expectEqual(@as(u64, 6564), o.varOf("cab", "saw").?);
    try testing.expectEqual(@as(u64, 6564), o.varOf("arch", "got").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab/Screen#0").?.state);
}

test "A4 movement 3: an heir does not mistake its inheritance for a message" {
    // The bug movement 3 found in movement 2's wire format. The grant
    // record was $6772_0001 — the architected mark in the half the
    // dispatcher does not mask, and tag ONE in the half it does. Tags are
    // handed out from 1, so every program's first message collided, and a
    // sole-case actor does no tag test at all. The estate was handled as
    // an ordinary Draw, silently, with the descriptor slot read as a field.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\message Draw { n u64 }
        \\actor Screen(tick u64) {
        \\    var frame region [64]u64
        \\    grant frame to boss
        \\    halt ok
        \\}
        \\actor Cabinet() {
        \\    var draws u64 = 0
        \\    spawn Screen(1) restarts 0 watchdog 0
        \\    serve {
        \\        case Draw(d):
        \\            draws += 1
        \\    }
        \\}
        \\system { cab = Cabinet() }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 1), o.stats.grants);
    // Nobody ever sent a Draw.
    try testing.expectEqual(@as(u64, 0), o.varOf("cab", "draws").?);
}

test "A4 movement 3: the chain ends where somebody declines to extend it" {
    // The same program as the chain of custody, minus one word: the screen
    // grants WITHOUT `onward`, so the Cabinet receives read|write and not
    // the right to delegate. It adopts and reads happily; its own grant is
    // refused. Attenuation is not advisory.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\actor Screen(tick u64) {
        \\    var frame region [64]u64
        \\    frame[0] = 6564
        \\    grant frame to boss
        \\    halt ok
        \\}
        \\actor Archive(name u64) {
        \\    var kept region [64]u64
        \\    var got u64 = 0
        \\    serve {
        \\        case handoff(h):
        \\            adopt h as kept
        \\            got = kept[0]
        \\    }
        \\}
        \\actor Cabinet(arch addr) {
        \\    var frame region [64]u64
        \\    var saw u64 = 0
        \\    spawn Screen(1) restarts 0 watchdog 0
        \\    serve {
        \\        case handoff(h):
        \\            adopt h as frame
        \\            saw = frame[0]
        \\            grant frame to arch
        \\    }
        \\}
        \\system { arch = Archive(1) on 0 cab = Cabinet(arch) on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    // The estate reached the executor and stopped there.
    try testing.expectEqual(@as(u64, 1), o.stats.grants);
    try testing.expectEqual(@as(u64, 6564), o.varOf("cab", "saw").?);
    try testing.expectEqual(@as(u64, 0), o.varOf("arch", "got").?);
}

test "A4 movement 3: a region may not leave its memory domain" {
    // RAM is per-core, so a region's base is a core-local address. Carried
    // to another core it would still be a well-formed capability — right
    // length, fresh token, correct verbs — over memory the grantee never
    // named. The identical program, with the Archive placed on core 1:
    // the first succession still runs, the crossing is refused, and the
    // Archive reads nothing, because it was handed nothing.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\actor Screen(tick u64) {
        \\    var frame region [64]u64
        \\    frame[0] = 6564
        \\    grant frame to boss onward
        \\    halt ok
        \\}
        \\actor Archive(name u64) {
        \\    var kept region [64]u64
        \\    var got u64 = 0
        \\    serve {
        \\        case handoff(h):
        \\            adopt h as kept
        \\            got = kept[0]
        \\    }
        \\}
        \\actor Cabinet(arch addr) {
        \\    var frame region [64]u64
        \\    var saw u64 = 0
        \\    spawn Screen(1) restarts 0 watchdog 0
        \\    serve {
        \\        case handoff(h):
        \\            adopt h as frame
        \\            saw = frame[0]
        \\            grant frame to arch
        \\    }
        \\}
        \\system { arch = Archive(1) on 1 cab = Cabinet(arch) on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 1), o.stats.grants);
    try testing.expectEqual(@as(u64, 6564), o.varOf("cab", "saw").?);
    try testing.expectEqual(@as(u64, 0), o.varOf("arch", "got").?);
}

test "A4 movement 3: a supervisor lends the estate down to the child it named" {
    // The honest gap movement 3 left, closed. Probate ran up (a screen to
    // its Cabinet) and across (the Cabinet to a peer it was wired to), but
    // never DOWN — `spawn` gave a supervisor no name for its child, so the
    // Cabinet could bury a screen but not write to one. `spawn Screen(1)
    // as screen` binds that name, and the estate flows the way A4.4 always
    // meant it to: the Cabinet holds the frame for the machine's whole
    // life, spawns a screen, and lends the frame to the screen it just
    // started — but only once the screen says it is ready. That ordering
    // is not ceremony: a supervisor cannot lend an estate to a child that
    // is still being born, because the grant claims a descriptor slot and
    // the child's own init would overwrite it. So the screen announces
    // itself to `boss` after its regions are staged, and the Cabinet
    // grants in reply. The screen signs for the estate and reads what the
    // Cabinet wrote — a successor, not a peer, receiving an inheritance.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\message Ready { x u64 }
        \\actor Screen(tick u64) {
        \\    var frame region [64]u64
        \\    var got u64 = 0
        \\    send boss, Ready{1}
        \\    serve {
        \\        case handoff(h):
        \\            adopt h as frame
        \\            got = frame[0]
        \\            halt ok
        \\    }
        \\}
        \\actor Cabinet() {
        \\    var frame region [64]u64
        \\    spawn Screen(1) as screen restarts 0 watchdog 0
        \\    serve {
        \\        case Ready(r):
        \\            frame[0] = 6564
        \\            grant frame to screen
        \\            halt ok
        \\    }
        \\}
        \\system { cab = Cabinet() on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    // One grant, downward, and the successor read the estate it was lent.
    try testing.expectEqual(@as(u64, 1), o.stats.grants);
    try testing.expectEqual(@as(u64, 6564), o.varOf("cab/Screen#0", "got").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab").?.state);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab/Screen#0").?.state);
}

test "A4.7 dynamic spawn: a screen started mid-serve, and lent the estate" {
    // The shape rocci actually needs. This morning's Cabinet spawned its
    // heir at boot; a real Cabinet spawns the next screen on a transition,
    // inside a `serve` handler. Here the Cabinet kicks itself, spawns the
    // screen in the `Kick` case — not the actor body — names it, and lends
    // it the frame once the screen reports ready. The child is born at
    // handler time, into a context the loader reserved for that spawn
    // site, and the capability aimed at it was staged before it ever ran.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\message Kick { n u64 }
        \\message Ready { x u64 }
        \\actor Screen(tick u64) {
        \\    var frame region [64]u64
        \\    var got u64 = 0
        \\    send boss, Ready{1}
        \\    serve {
        \\        case handoff(h):
        \\            adopt h as frame
        \\            got = frame[0]
        \\            halt ok
        \\    }
        \\}
        \\actor Cabinet() {
        \\    var frame region [64]u64
        \\    send self, Kick{0}
        \\    serve {
        \\        case Kick(k):
        \\            spawn Screen(1) as screen restarts 0 watchdog 0
        \\        case Ready(r):
        \\            frame[0] = 6564
        \\            grant frame to screen
        \\            halt ok
        \\    }
        \\}
        \\system { cab = Cabinet() on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 1), o.stats.grants);
    try testing.expectEqual(@as(u64, 6564), o.varOf("cab/Screen#0", "got").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab").?.state);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab/Screen#0").?.state);
}

test "A4.7 dynamic spawn: one site, two incarnations, one capability" {
    // The incarnation question, answered by test. The Cabinet has a single
    // spawn site — `case Kick: spawn Screen(1) as screen` — and fires it
    // twice. SPWN reuses the one context the loader reserved for that site,
    // bumping the generation; the child's RX ring lives in the near page,
    // which the restart does not move, so the parent's capability to
    // `screen` stays valid across the bump. The proof is that `send
    // screen, Ping` lands on BOTH lives: each incarnation hears 6564,
    // reports Done, and dies, and the second Done could not arrive if the
    // second `send` had gone nowhere. The old life is always dead before
    // the next SPWN, because the child halts synchronously inside its own
    // burst — the successor never restarts a living context.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\message Kick { n u64 }
        \\message Ready { life u64 }
        \\message Ping { v u64 }
        \\message Done { life u64 }
        \\actor Screen(life u64) {
        \\    var heard u64 = 0
        \\    send boss, Ready{life}
        \\    serve {
        \\        case Ping(p):
        \\            heard = p.v
        \\            send boss, Done{life}
        \\            halt ok
        \\    }
        \\}
        \\actor Cabinet() {
        \\    var cycles u64 = 0
        \\    send self, Kick{0}
        \\    serve {
        \\        case Kick(k):
        \\            spawn Screen(1) as screen restarts 0 watchdog 0
        \\        case Ready(r):
        \\            send screen, Ping{6564}
        \\        case Done(d):
        \\            cycles += 1
        \\            if cycles < 2 {
        \\                send self, Kick{0}
        \\            } else {
        \\                halt ok
        \\            }
        \\    }
        \\}
        \\system { cab = Cabinet() on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    // Two lives, each addressed down the same capability and each heard.
    try testing.expectEqual(@as(u64, 2), o.varOf("cab", "cycles").?);
    try testing.expectEqual(@as(u64, 6564), o.varOf("cab/Screen#0", "heard").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab").?.state);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab/Screen#0").?.state);
}

test "device row: the display is the frame clock — grant, present, get it back" {
    // rocci §2, in the flesh. Nobody calls a 6564 actor, so where does
    // 60Hz come from? Backpressure. The screen grants its frame to the
    // display and cannot draw again until the display returns it; the
    // completion IS the clock, the grant IS the pacing. Here the screen
    // presents three frames, bumping a marker each time, and cannot run
    // ahead of the glass — each Present waits for the PresentDone that a
    // single-buffered display only sends when it has finished the last.
    // The display counts what it presented and checksums the final frame:
    // proof the drawing reached the glass, not just that a message did.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\message Present { f grant }
        \\actor Screen(display addr) {
        \\    var frame region [8]u64
        \\    var frames u64 = 0
        \\    frame[0] = 6564
        \\    send display, Present{grant frame}
        \\    serve {
        \\        case done(frame):
        \\            frames += 1
        \\            if frames >= 3 {
        \\                quiesce
        \\            } else {
        \\                frame[0] = frame[0] + 1
        \\                send display, Present{grant frame}
        \\            }
        \\        case failed(frame):
        \\            quiesce
        \\    }
        \\}
        \\system {
        \\    scr = Screen(display) on 0
        \\    display = Display()
        \\}
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    // Three frames drawn, three presented, and the glass saw the last one
    // the screen drew — frame[0] = 6564 + 2, the rest of the region zero.
    try testing.expectEqual(@as(u64, 3), o.varOf("scr", "frames").?);
    try testing.expectEqual(@as(u64, 3), o.display_frames);
    try testing.expectEqual(@as(u64, 6566), o.display_checksum);
}

test "device row: the APU is a fire-and-forget sink — tones, no answer" {
    // rocci §1: `W4.tone!(...)` becomes `send apu, Tone{...}`, fire and
    // forget, as sound should be. The APU takes a plain message — no
    // reply window, no completion — and counts what it was told to play.
    // A headless machine cannot make a sound, but it can say truthfully
    // how many were asked for and what the last one was, which is exactly
    // enough to prove the wire without pretending to be a speaker.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\message Tone { n u64 }
        \\actor Player(apu addr) {
        \\    var played u64 = 0
        \\    send apu, Tone{100}
        \\    send apu, Tone{200}
        \\    send apu, Tone{300}
        \\    played = 3
        \\    halt ok
        \\}
        \\system {
        \\    p = Player(apu) on 0
        \\    apu = Apu()
        \\}
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    // Three tones asked for, three played; the sum proves the values on
    // the wire (100 + 200 + 300), independent of the order a fire-and-
    // forget burst arrives in.
    try testing.expectEqual(@as(u64, 3), o.apu_tones);
    try testing.expectEqual(@as(u64, 600), o.apu_sum);
    try testing.expectEqual(@as(u64, 3), o.varOf("p", "played").?);
}

test "device row: the pad pushes, the actor latches — input as a subscription" {
    // rocci §1: a WASM-4 game polls the gamepad; a 6564 actor is pushed
    // to. The Game subscribes once with an ordinary ask — `send pad,
    // Poll{}`, where `Poll -> Pad` — and the pad streams `Pad{buttons}`
    // to the ask's reply window, one per input frame, using the ask's
    // echoed tag. No new wiring: a subscription is an ask whose answer
    // never stops coming. The trace is a fixed sequence, so the run is a
    // recording that replays bit for bit (§4).
    const trace = [_]u64{ 1, 4, 6 };
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\message Pad { buttons u64 }
        \\message Poll -> Pad {}
        \\actor Game(pad addr) {
        \\    var latched u64 = 0
        \\    var frames u64 = 0
        \\    send pad, Poll{}
        \\    serve {
        \\        case Pad(p):
        \\            latched = p.buttons
        \\            frames += 1
        \\            if frames >= 3 {
        \\                quiesce
        \\            }
        \\    }
        \\}
        \\system {
        \\    g = Game(pad) on 0
        \\    pad = Pad()
        \\}
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0, .pad_trace = &trace });
    defer o.deinit();
    // Three inputs pushed, three latched, and the last one held — pushes
    // are interval-apart, so they arrive in the order they were recorded.
    try testing.expectEqual(@as(u64, 3), o.pad_pushed);
    try testing.expectEqual(@as(u64, 3), o.varOf("g", "frames").?);
    try testing.expectEqual(@as(u64, 6), o.varOf("g", "latched").?);
}

test "Tier 1 vectors: a lanewise compare masks, and the mask counts (VFCMP)" {
    // The deferred mask surface (A1.4 left it for "its first workload" —
    // the SoA pipes). `xs == 20.0` sets a 1.0/0.0 lane mask, `.reduce(+)`
    // sums it, `int(...)` is the popcount; every predicate rides one op
    // with the comparison in A. Four lanes equal 20; three are >= 25.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\actor Counter() {
        \\    var xs vec
        \\    var m vec
        \\    var eq u64 = 0
        \\    var ge u64 = 0
        \\    xs = [10.0, 20.0, 20.0, 30.0, 20.0, 40.0, 20.0, 50.0]
        \\    m = xs == 20.0
        \\    eq = int(m.reduce(+))
        \\    m = xs >= 25.0
        \\    ge = int(m.reduce(+))
        \\    halt ok
        \\}
        \\system { c = Counter() on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 4), o.varOf("c", "eq").?);
    try testing.expectEqual(@as(u64, 3), o.varOf("c", "ge").?);
}

test "Tier 1 vectors: `where` is lanewise select — the mask that counts now chooses" {
    // VSEL never landed: the $?7 vector column is spent whole (VFCMP took
    // the last slot). It didn't need to. `where(cond, a, b)` lowers to the
    // 1.0/0.0 mask VFCMP already makes and a blend `b + mask·(a − b)` — the
    // same mask surface that popcounts (VRADD) now also selects. Two proofs:
    // (1) the pipe-recycle wrap — take `xs + 160` where a lane has run off
    // the left edge (xs <= 0), else keep it; and (2) a select between two
    // INDEPENDENT vectors, proving it is a true choose, not a masked add.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\actor Chooser() {
        \\    var xs vec
        \\    var wrapped vec
        \\    var flags vec
        \\    var hi vec
        \\    var lo vec
        \\    var picked vec
        \\    var wsum u64 = 0
        \\    var psum u64 = 0
        \\    // recycle: two lanes at 0.0 wrap by +160, the six others hold.
        \\    xs = [40.0, 20.0, 0.0, 80.0, 200.0, 0.0, 10.0, 160.0]
        \\    wrapped = where(xs <= 0.0, xs + 160.0, xs)
        \\    // [40, 20, 160, 80, 200, 160, 10, 160] = 830
        \\    wsum = int(wrapped.reduce(+))
        \\    // select between two whole vectors: even lanes take hi, odd lo.
        \\    flags = [1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0]
        \\    hi = [100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0]
        \\    lo = [7.0, 7.0, 7.0, 7.0, 7.0, 7.0, 7.0, 7.0]
        \\    picked = where(flags >= 0.5, hi, lo)
        \\    // [100, 7, 100, 7, 100, 7, 100, 7] = 428
        \\    psum = int(picked.reduce(+))
        \\    halt ok
        \\}
        \\system { c = Chooser() on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 830), o.varOf("c", "wsum").?);
    try testing.expectEqual(@as(u64, 428), o.varOf("c", "psum").?);
}

test "byte memory: STB writes one byte of eight, LDB reads it back zero-extended" {
    // The 6564 widened the 6502's word to 64 bits, so every STA writes eight
    // bytes. A byte framebuffer wants one. STB stores A's low byte and leaves
    // the other seven untouched (memory is bytes — no read-modify-write);
    // LDB reads a byte zero-extended. Both ride (ind),Y off a near base cell,
    // exactly as a joe region's `frame[i]` will.
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
    });
    defer m.deinit();
    const src =
        \\        .org $1000
        \\        LDA ##$2000                 ; region base
        \\        STA $10                     ; park it in a near cell
        \\        LDA ##$1122334455667788     ; a full word at the base
        \\        STA !$2000
        \\        LDY #3                      ; byte index 3
        \\        LDA #$AB
        \\        STB ($10),Y                 ; write one byte at $2000+3
        \\        LDB ($10),Y                 ; read it back, zero-extended
        \\        STA !$2050                  ; record the loaded byte
        \\        LDA !$2000                  ; the word, after the byte poke
        \\        STA !$2058
        \\        HLT
    ;
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    const at = struct {
        fn word(mm: *Machine, addr: u64) u64 {
            return std.mem.readInt(u64, mm.cores[0].ram[addr - 0x1000 ..][0..8], .little);
        }
    }.word;
    // LDB zero-extended the byte: A held exactly $AB.
    try testing.expectEqual(@as(u64, 0xAB), at(&m, 0x2050));
    // Only byte 3 changed: $55 → $AB, the other seven bytes intact.
    try testing.expectEqual(@as(u64, 0x11223344AB667788), at(&m, 0x2058));
}

test "byte regions: joe `region [N]u8` stores and reads bytes (LDB/STB path)" {
    // A byte region is a framebuffer: one byte per element, indexed by the
    // byte itself (no ×8), drawn with STB and read with LDB. A for-loop
    // fills ten bytes 1..10; a byte poke must not disturb its neighbours,
    // which the sum 55 and the two spot reads together prove.
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        \\actor Bytes() {
        \\    var buf region [10]u8
        \\    var a u64 = 0
        \\    var b u64 = 0
        \\    var s u64 = 0
        \\    for r in 0..10 {
        \\        buf[r] = r + 1
        \\    }
        \\    a = buf[3]
        \\    b = buf[7]
        \\    for r in 0..10 {
        \\        s += buf[r]
        \\    }
        \\    halt ok
        \\}
        \\system { x = Bytes() on 0 }
    , .{ .loss_ppm4k = 0, .dup_ppm4k = 0 });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 4), o.varOf("x", "a").?);
    try testing.expectEqual(@as(u64, 8), o.varOf("x", "b").?);
    try testing.expectEqual(@as(u64, 55), o.varOf("x", "s").?);
}

test "joey-bird: the whole society runs — frame clock, input, sound, death" {
    // The bird, in the flesh, on the device row it was written against.
    // The display is the frame clock (each `Present` waits on the last
    // `done`); the pad streams input the bird latches and flaps on; the
    // APU takes the flap and the death; and when the bird hits the floor
    // it tells the referee its score and dies. Nobody calls this actor —
    // the display writes back, the pad speaks up, the bird decides. A
    // fixed input trace makes the whole run a recording that replays bit
    // for bit (rocci §4).
    const trace = [_]u64{ 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0 };
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        @embedFile("programs/joe/joey/joey.joe"),
        .{ .loss_ppm4k = 0, .dup_ppm4k = 0, .pad_trace = &trace },
    );
    defer o.deinit();
    // The bird flapped (input reached it and moved it), presented frames
    // (the display counted them), played tones (flaps, points, and the
    // death), and died ON A PIPE — the pixel-peek, not the floor. Golden
    // values: the run is deterministic, so these are exact. With these two
    // flaps she cleared six gaps and then, when the input ran out and she
    // fell, dropped out of the gap and clipped a pipe at frame 61 — at
    // height ~102, well above the floor (134). `cause = 2` is the pipe;
    // `cause = 1` would be the floor. Nine tones = 2 flaps + 6 points + 1
    // death. The collision is the byte framebuffer read back under her.
    try testing.expectEqual(@as(u64, 61), o.varOf("game", "t").?);
    try testing.expectEqual(@as(u64, 61), o.display_frames);
    try testing.expectEqual(@as(u64, 2), o.varOf("game", "flaps").?);
    try testing.expectEqual(@as(u64, 6), o.varOf("game", "score").?);
    try testing.expectEqual(@as(u64, 9), o.apu_tones);
    try testing.expectEqual(@as(u64, 30), o.pad_pushed);
    // She died on a pipe (cause 2), not the floor (cause 1) — and her
    // height at death proves it: a pipe body, not the ground.
    try testing.expectEqual(@as(u64, 2), o.varOf("game", "cause").?);
    try testing.expect(@as(f64, @bitCast(o.varOf("game", "y").?)) < 134.0);
    // The bird died and told the referee, exactly once.
    try testing.expectEqual(@as(u64, 1), o.varOf("ref", "overs").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("game").?.state);
    try testing.expectEqual(
        o.varOf("game", "score").?,
        o.varOf("ref", "final_score").?,
    );
}

test "joey-bird: the pipes are endless — a longer-lived bird laps the field (where)" {
    // With the old eight fixed pipes the score capped at eight: each pipe
    // crossed the player once and was gone. `where` recycles a pipe off the
    // left edge back to the right (+160, phase-preserving), so a bird kept
    // in the gap long enough laps the whole field and scores again. This
    // trace flaps every 24 frames — a rough hover inside the [8,100) gap —
    // and she clears the eighth pipe (one full lap, ~frame 80) and keeps
    // going, scoring past eight before drift eventually walks her out of the
    // gap onto a pipe. Observed: she scores 10 by frame 100. The score past
    // eight is the point: only a recycled field can produce it.
    var trace: [300]u64 = .{0} ** 300;
    var i: usize = 0;
    while (i < trace.len) : (i += 24) trace[i] = 1;
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        @embedFile("programs/joe/joey/joey.joe"),
        .{ .loss_ppm4k = 0, .dup_ppm4k = 0, .pad_trace = &trace },
    );
    defer o.deinit();
    // Past the eight-pipe cap: the field wrapped and scored a second time.
    try testing.expect(o.varOf("game", "score").? > 8);
}

test "A4.9 capability-passing spawn: the Cabinet spawns the bird, lending the device row" {
    // The sketch's §3 Cabinet, finally expressible. The Cabinet holds the
    // display, the pad, and the APU for the whole run and LENDS them to
    // each Game it spawns — `spawn Game(display, pad, apu)` hands the child
    // its own windows onto the devices the Cabinet holds. The bird plays,
    // dies, tells the Cabinet its score, and the Cabinet inserts another
    // coin. Three lives; the first has input and flies, the rest fall (the
    // pad's one stream is spent on the first subscriber). That a SPAWNED
    // child presents frames and plays tones at all is the proof: without
    // capability-passing spawn it could not reach a device it was handed.
    const trace = [_]u64{ 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0 };
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        @embedFile("programs/joe/joey/cabinet.joe"),
        .{ .loss_ppm4k = 0, .dup_ppm4k = 0, .pad_trace = &trace },
    );
    defer o.deinit();
    // Three coins, and the best life is the one that got input (score 10,
    // exactly the top-level bird's run) — capabilities threaded through the
    // spawn to every incarnation.
    try testing.expectEqual(@as(u64, 3), o.varOf("cab", "games").?);
    try testing.expectEqual(@as(u64, 10), o.varOf("cab", "best").?);
    // The spawned Game reached the lent devices: it presented frames and
    // played tones through capabilities it was handed, not born with.
    try testing.expect(o.display_frames >= 3);
    try testing.expect(o.apu_tones >= 3);
    try testing.expect(o.pad_pushed >= 1);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab").?.state);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab/Game#0").?.state);
}

test "joey-bird arcade: three screens, and the pad follows the living one" {
    // The whole state machine (sketch §3): Title -> Game -> GameOver ->
    // Title. Each screen is a different actor kind — a different context —
    // spawned and equipped by the Cabinet, and each subscribes to the pad
    // when it wakes. The re-subscribing pad (§7.8) aims the input at
    // whoever last Polled, so every screen hears the press it waits for:
    // the Title the one that starts the game, the bird its inputs, the
    // GameOver the one that drops another coin. THE LOOP COMPLETING IS THE
    // PROOF — without re-subscription only the Title would ever hear the
    // pad, GameOver could never advance, and the machine would never come
    // back to the Title. A held button drives the whole lap.
    const trace = [_]u64{1} ** 200;
    var o = try @import("joe_run.zig").simulate(testing.allocator,
        @embedFile("programs/joe/joey/arcade.joe"),
        .{ .loss_ppm4k = 0, .dup_ppm4k = 0, .pad_trace = &trace },
    );
    defer o.deinit();
    // One full lap: the Cabinet returns to the Title and closes the arcade.
    try testing.expectEqual(@as(u64, 2), o.varOf("cab", "loops").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab").?.state);
    // All three screens heard the pad in turn — the redirect reached each.
    // Golden, because the run is deterministic: the Title's start press,
    // the bird's inputs across its life, the game-over coin.
    try testing.expectEqual(@as(u64, 1), o.varOf("cab/Title#2", "presses").?);
    try testing.expectEqual(@as(u64, 66), o.varOf("cab/Game#0", "heard").?);
    try testing.expectEqual(@as(u64, 4), o.varOf("cab/GameOver#1", "presses").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab/Title#2").?.state);
    try testing.expectEqual(machine.CtxState.halted, o.instance("cab/GameOver#1").?.state);
}

test "A4 movement 2: succession — a capability moves, with provenance" {
    // Rocci's fourth costume, in miniature: a dying screen hands its live
    // framebuffer to its successor. No copy, no redraw — the capability
    // moves, the memory stays exactly where it is.
    const grantor =
        \\        .org $1000
        \\        LDA ##$4000         ; the region: base…
        \\        STA $100            ;   (descriptor slot 8)
        \\        LDA ##$020F_0000_0000_0000  ; REGION flag | verbs rwsg
        \\        STA $108
        \\        LDA ##512
        \\        STA $110
        \\        LDA ##$6564         ; our token
        \\        STA $118
        \\        LDA #4              ; SQE: op = grant
        \\        STA !$2400
        \\        LDA ##$FF00_0000_0000_0000
        \\        STA !$2408          ; to the successor, via PTT 0
        \\        LDA #8
        \\        STA !$2410          ; source descriptor slot
        \\        LDA ##$1_0000_0003  ; verbs granted: read|write (no send, no grant)
        \\        STA !$2418
        \\        SEND 0
        \\        HLT
    ;
    const heir =
        \\        .org $1400
        \\        RECV 2
        \\wait:   LSTN 1
        \\        CQPOP 1
        \\        BEQ wait
        \\        AND ##$FFFF
        \\        CMP #3              ; a delivery?
        \\        BNE wait
        \\        STX $200            ; where the grant record landed
        \\        HLT
    ;
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x8000,
    });
    defer m.deinit();
    // The successor's RX ring, and the grantor's capability to reach it.
    m.setPtt(0, 0, .{
        .prefix_hi = 0xfd65_6400_0000_0000,
        .prefix_lo = ring.PttEntry.loFrom(0, 1, ring.slot_rx),
        .rights = .{ .send = true },
        .dialect = .msg,
        .token = 0x6564,
    });
    for ([_]u8{ 0, 1 }) |c| {
        m.setRing(0, c, ring.slot_sq, .{
            .base = 0x2400 + @as(u64, c) * 0x200,
            .cap_log2 = 0,
            .entry_size = ring.sq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        m.setRing(0, c, ring.slot_cq, .{
            .base = 0x2000 + @as(u64, c) * 0x200,
            .cap_log2 = 4,
            .entry_size = ring.cq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
    }
    m.setRing(0, 1, ring.slot_rx, .{
        .base = 0x2800,
        .cap_log2 = 1,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0x6564,
    });
    var entry_bytes: [32]u8 = undefined;
    const rx = ring.RxEntry{ .buf = 0x2900, .cap = 64, .filled = 0, .cookie = 0x2900 };
    for (rx.pack(), 0..) |w, i| std.mem.writeInt(u64, entry_bytes[i * 8 ..][0..8], w, .little);
    m.load(0, 0x2800, &entry_bytes);

    var g = try asm6564.assemble(testing.allocator, grantor, null);
    defer g.deinit();
    var h = try asm6564.assemble(testing.allocator, heir, null);
    defer h.deinit();
    m.load(0, g.origin, g.code);
    m.load(0, h.origin, h.code);
    try m.spawn(0, 1, 0x1400, 0x3800, 0); // the heir listens first
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    _ = try m.run();

    try testing.expectEqual(@as(u64, 1), m.stats.grants);
    // The grantor surrendered its copy: the token is gone, so the region
    // it just handed on is no longer reachable through the old capability.
    const old_token = std.mem.readInt(u64, m.cores[0].contexts[0].near[0x118..][0..8], .little);
    try testing.expectEqual(@as(u64, 0), old_token);

    // The heir received a grant record — and hardware chose the slot.
    const landed = std.mem.readInt(u64, m.cores[0].contexts[1].near[0x200..][0..8], .little);
    const rec = m.cores[0].ram[@intCast(landed - machine.ram_base)..][0..56];
    const w = struct {
        fn at(p: []const u8, i: usize) u64 {
            return std.mem.readInt(u64, p[i * 8 ..][0..8], .little);
        }
    }.at;
    try testing.expectEqual(ring.grant_record_tag, w(rec, 0));
    const new_slot: u8 = @truncate(w(rec, 1));
    try testing.expect(new_slot >= 8);
    try testing.expectEqual(@as(u64, 0x4000), w(rec, 3)); // same memory…
    try testing.expectEqual(@as(u64, 512), w(rec, 4)); // …same extent
    try testing.expect(w(rec, 2) != 0x6564); // …fresh token, not the old one
    // Provenance: who granted it, from which of their slots, in which life.
    try testing.expectEqual(@as(u64, 0), w(rec, 5) & 0xFFFF); // core 0
    try testing.expectEqual(@as(u64, 0), (w(rec, 5) >> 16) & 0xFFFF); // ctx 0
    try testing.expectEqual(@as(u64, 8), w(rec, 6)); // their slot 8

    // The derived capability carries the verbs it was granted — read and
    // write, but NOT grant: this heir cannot pass it on again.
    const doff = @as(usize, new_slot) * ring.desc_size;
    const dw1 = std.mem.readInt(u64, m.cores[0].contexts[1].near[doff + 8 ..][0..8], .little);
    const verbs: ring.Verbs = @bitCast(@as(u4, @truncate(dw1 >> 48)));
    try testing.expect(verbs.read and verbs.write);
    try testing.expect(!verbs.grant);
    // And it is a region, with hardware's fresh token.
    try testing.expect(@as(u8, @truncate(dw1 >> 56)) & ring.desc_flag_region != 0);
    try testing.expectEqual(
        w(rec, 2),
        std.mem.readInt(u64, m.cores[0].contexts[1].near[doff + 24 ..][0..8], .little),
    );
}

test "A4 movement 2: what you do not hold, you cannot pass on" {
    // Three refusals, one mechanism: a revoked capability (token zero), a
    // capability granted out to silicon (OWNED), and one whose holder was
    // never given the right to delegate.
    const src =
        \\        .org $1000
        \\        LDA #4
        \\        STA !$2400
        \\        LDA ##$FF00_0000_0000_0000
        \\        STA !$2408
        \\        LDA #8
        \\        STA !$2410
        \\        LDA ##$1_0000_0003
        \\        STA !$2418
        \\        SEND 0
        \\wait:   LSTN 1
        \\        CQPOP 1
        \\        BEQ wait
        \\        STA $200
        \\        HLT
    ;
    const cases = [_]struct { w1: u64, token: u64 }{
        .{ .w1 = 0x020F_0000_0000_0000, .token = 0 }, // revoked
        .{ .w1 = 0x060F_0000_0000_0000, .token = 0x6564 }, // OWNED by silicon
        .{ .w1 = 0x0203_0000_0000_0000, .token = 0x6564 }, // holder has no grant verb
    };
    for (cases) |c| {
        var m = try Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 2,
            .ram_size = 0x8000,
        });
        defer m.deinit();
        m.setPtt(0, 0, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(0, 1, ring.slot_rx),
            .rights = .{ .send = true },
            .dialect = .msg,
            .token = 0x6564,
        });
        m.setRing(0, 0, ring.slot_sq, .{
            .base = 0x2400,
            .cap_log2 = 0,
            .entry_size = ring.sq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        m.setRing(0, 0, ring.slot_cq, .{
            .base = 0x2000,
            .cap_log2 = 4,
            .entry_size = ring.cq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, 0x4000, .little);
        m.writeNear(0, 0, 0x100, &buf);
        std.mem.writeInt(u64, &buf, c.w1, .little);
        m.writeNear(0, 0, 0x108, &buf);
        std.mem.writeInt(u64, &buf, 512, .little);
        m.writeNear(0, 0, 0x110, &buf);
        std.mem.writeInt(u64, &buf, c.token, .little);
        m.writeNear(0, 0, 0x118, &buf);
        var out = try asm6564.assemble(testing.allocator, src, null);
        defer out.deinit();
        m.load(0, out.origin, out.code);
        try m.spawn(0, 0, 0x1000, 0x3000, 0);
        _ = try m.run();
        try testing.expectEqual(@as(u64, 0), m.stats.grants);
        const verdict = std.mem.readInt(u64, m.cores[0].contexts[0].near[0x200..][0..8], .little);
        const status: ring.Status = @enumFromInt(@as(u8, @truncate(verdict >> 8)));
        try testing.expectEqual(ring.Status.reject_capability, status);
    }
}

test "A4 movement 1: the RBC rejects a lying dialect claim, compiler or no compiler" {
    // The thesis test. A hand-written program stamps a MSG claim into an
    // SQE aimed at a RAW endpoint — the bypass a static check cannot see.
    // The right lives in the capability, so the machine rejects it at the
    // PTT, in the same breath it checks the token, and no bytes move.
    const src =
        \\        .org $1000
        \\        LDA ##$2_0000_0001  ; op = send | hint claim = msg (2)
        \\        STA !$2400
        \\        LDA ##$FF00_0000_0000_0000
        \\        STA !$2408
        \\        LDA ##$2500
        \\        STA !$2410
        \\        LDA ##$1_0000_0008
        \\        STA !$2418
        \\        SEND 0
        \\wait:   LSTN 1
        \\        CQPOP 1
        \\        BEQ wait
        \\        STA $860            ; the verdict, for the test to read
        \\        HLT
    ;
    for ([_]ring.Dialect{ .raw, .msg }) |endpoint| {
        var m = try Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 1,
            .ram_size = 0x8000,
        });
        defer m.deinit();
        try m.attachDevice(0xFF00, 0, .{ .console = @import("dev.zig").Console.init(testing.allocator) });
        m.setPtt(0, 0, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(0xFF00, 0, 0),
            .rights = .{ .send = true },
            .dialect = endpoint,
            .token = 0,
        });
        m.setRing(0, 0, ring.slot_sq, .{
            .base = 0x2400,
            .cap_log2 = 0,
            .entry_size = ring.sq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        m.setRing(0, 0, ring.slot_cq, .{
            .base = 0x2000,
            .cap_log2 = 4,
            .entry_size = ring.cq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        var out = try asm6564.assemble(testing.allocator, src, null);
        defer out.deinit();
        m.load(0, out.origin, out.code);
        try m.spawn(0, 0, 0x1000, 0x3000, 0);
        _ = try m.run();
        const verdict = std.mem.readInt(u64, m.cores[0].contexts[0].near[0x860..][0..8], .little);
        const status: ring.Status = @enumFromInt(@as(u8, @truncate(verdict >> 8)));
        if (endpoint == .raw) {
            // The claim says msg, the endpoint IS raw: rejected, and the
            // console never heard a byte.
            try testing.expectEqual(ring.Status.reject_capability, status);
            try testing.expectEqual(@as(usize, 0), m.device(0xFF00).?.console.out.items.len);
        } else {
            // Same program, honest endpoint: through it goes.
            try testing.expectEqual(ring.Status.ok, status);
            try testing.expectEqual(@as(usize, 8), m.device(0xFF00).?.console.out.items.len);
        }
    }
}

test "the one-shot timer side door: a dropped timeout is a park with no wake" {
    // §6.3's discipline, demonstrated rather than asserted. A timeout is
    // a verdict, so §4.2 lets it drop when a CQ is full — and for an
    // AUTO_REARM timer that is harmless, because the next tick re-derives
    // the wake. A ONE-SHOT has no next tick: lose it and the actor waits
    // forever with nothing outstanding. This is why a liveness-bearing
    // timer must auto-rearm.
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 0, // one record, and the ack will take it
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.load(0, 0x1000, &.{0xDB});
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    // The queue fills with an ordinary verdict…
    m.postCompletion(0, 0, ring.slot_cq, .{ .tag = .send, .status = .ok, .byte_count = 0, .cookie = 1 });
    // …and the one-shot's wake arrives to no room at all.
    m.postCompletion(0, 0, ring.slot_cq, .{ .tag = .send, .status = .timeout, .byte_count = 0, .cookie = 0x77 });
    try testing.expectEqual(@as(u64, 1), m.stats.cq_overflows);
    // Dropped, and the context is NOT faulted: by the narrowed rule this
    // is a survivable loss — which is exactly right for a rearming timer
    // and exactly the hazard for a one-shot.
    try testing.expectEqual(machine.Fault.none, m.cores[0].contexts[0].fault);
}

test "compiled timers auto-rearm: joe never stages a liveness one-shot" {
    // The corpus side of §6.3's discipline. joe's `after` is the only
    // timer the language can express, and it must tick forever.
    var r = try @import("joe.zig").compile(testing.allocator,
        \\message Go { }
        \\actor A(peer addr) {
        \\    serve {
        \\        case Go(_):
        \\            send peer, Go{}
        \\        after 500:
        \\            send peer, Go{}
        \\    }
        \\}
    , "A", .{}, null);
    defer r.deinit();
    try testing.expect(r.uses_timer);
    // $202 = op txr | flags AUTO_REARM — the flag is in the staged word,
    // not in a comment.
    try testing.expect(std.mem.indexOf(u8, r.asm_text, "LDA ##$202") != null);
}

// ── The generic .asm runner: the retired harnesses' scenarios, run from
//    the programs' own contracts (src/asm_run.zig). Each program carries
//    its deployment; tests that need another shape hand simulateSystem a
//    paragraph of system text — the harness reduced to its data. ──

const asm_run = @import("asm_run.zig");

const asm_src = struct {
    const supervisor = [_]asm_run.Source{
        .{ .name = "supervisor.asm", .text = @embedFile("programs/asm/supervisor.asm") },
        .{ .name = "worker.asm", .text = @embedFile("programs/asm/worker.asm") },
    };
    const ring = [_]asm_run.Source{
        .{ .name = "ring_node.asm", .text = @embedFile("programs/asm/ring_node.asm") },
    };
    const bigbrother = [_]asm_run.Source{
        .{ .name = "fanin_sink.asm", .text = @embedFile("programs/asm/fanin_sink.asm") },
        .{ .name = "flood_sender.asm", .text = @embedFile("programs/asm/flood_sender.asm") },
    };
    const scatter = [_]asm_run.Source{
        .{ .name = "scatter_coord.asm", .text = @embedFile("programs/asm/scatter_coord.asm") },
        .{ .name = "scatter_worker.asm", .text = @embedFile("programs/asm/scatter_worker.asm") },
    };
    const pipeline = [_]asm_run.Source{
        .{ .name = "pipe_source.asm", .text = @embedFile("programs/asm/pipe_source.asm") },
        .{ .name = "pipe_stage.asm", .text = @embedFile("programs/asm/pipe_stage.asm") },
        .{ .name = "pipe_sink.asm", .text = @embedFile("programs/asm/pipe_sink.asm") },
    };
    const forkjoin = [_]asm_run.Source{
        .{ .name = "fj_root.asm", .text = @embedFile("programs/asm/fj_root.asm") },
        .{ .name = "fj_lieutenant.asm", .text = @embedFile("programs/asm/fj_lieutenant.asm") },
        .{ .name = "fj_pass.asm", .text = @embedFile("programs/asm/fj_pass.asm") },
        .{ .name = "fanin_sink.asm", .text = @embedFile("programs/asm/fanin_sink.asm") },
    };
    const hello = [_]asm_run.Source{
        .{ .name = "hello.asm", .text = @embedFile("programs/asm/hello.asm") },
    };
    const periph = [_]asm_run.Source{
        .{ .name = "periph.asm", .text = @embedFile("programs/asm/periph.asm") },
    };
    const mandel = [_]asm_run.Source{
        .{ .name = "mandel.asm", .text = @embedFile("programs/asm/mandel.asm") },
    };
};

const clean_fabric = asm_run.Options{ .loss_ppm4k = 0, .dup_ppm4k = 0 };
const ringSystem = asm_run.ringSystem;
const floodSystem = asm_run.floodSystem;

fn ringFinishers(o: *const asm_run.Outcome) struct { count: usize, node0: bool } {
    var count: usize = 0;
    var node0 = false;
    for (o.instances) |inst| {
        for (inst.vars) |v| {
            if (std.mem.eql(u8, v.name, "finisher") and v.value != 0) {
                count += 1;
                if (std.mem.eql(u8, inst.name, "n0")) node0 = true;
            }
        }
    }
    return .{ .count = count, .node0 = node0 };
}

// ── Phase 3: supervision ─────────────────────────────────────────────────

test "supervision tree: restarts, budgets, watchdog, accumulated work" {
    var o = try asm_run.simulate(testing.allocator, &asm_src.supervisor, .{});
    defer o.deinit();
    // Reliable workers met quota and exited clean.
    try testing.expectEqual(@as(u64, 12), o.varOf("sup", "p1").?);
    try testing.expectEqual(@as(u64, 12), o.varOf("sup", "p3").?);
    // The crasher produced 5 items per incarnation across 4 lives (initial +
    // 3 restarts) — its RAM progress cell survived every SPWN.
    try testing.expectEqual(@as(u64, 20), o.varOf("sup", "p2").?);
    // The hanger produced 3 items per incarnation across 3 lives (initial +
    // 2 restarts); each life ended in a watchdog trip, not a BRK.
    try testing.expectEqual(@as(u64, 9), o.varOf("sup", "p4").?);
    try testing.expectEqual(@as(u64, 3), o.stats.watchdog_trips);
    try testing.expectEqual(machine.Fault.watchdog, o.instance("w4").?.fault);
    // Total restarts across both budgets.
    try testing.expectEqual(@as(u64, 5), o.varOf("sup", "restarts").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("sup").?.state);
    // Abandoned honestly: both unreliable workers' last lives stay faulted.
    try testing.expectEqual(machine.CtxState.faulted, o.instance("w2").?.state);
    try testing.expectEqual(machine.CtxState.faulted, o.instance("w4").?.state);
    try testing.expectEqual(machine.StopReason.faulted, o.reason);
}

test "a hang without a watchdog starves the whole core (the old finding)" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x4000,
        .max_cycles = 20_000,
    });
    defer m.deinit();
    const src =
        \\        .org $1000
        \\spin:   BRA spin
    ;
    var out = try asm6564.assemble(testing.allocator, src, null);
    defer out.deinit();
    m.load(0, out.origin, out.code);
    // No watchdog: the spinner holds the pipeline until max_cycles. Its
    // sibling never runs a single instruction.
    m.linkSupervisor(0, 0, 1, ring.slot_cq);
    try m.spawn(0, 0, 0x1000, 0x2000, 0);
    try testing.expectEqual(machine.StopReason.max_cycles, try m.run());
}

test "watchdog force-faults a spinner and its exit link reports it" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    // ctx1 spins forever; ctx0 supervises and records the obituary.
    const spinner_src =
        \\        .org $1200
        \\spin:   BRA spin
    ;
    const sup_src =
        \\        .org $1000
        \\wait:   LSTN 1
        \\        CQPOP 1
        \\        BEQ wait
        \\        STA !$2280      ; exit completion word0
        \\        STX !$2288      ; cookie (child id)
        \\        HLT
    ;
    var spinner_out = try asm6564.assemble(testing.allocator, spinner_src, null);
    defer spinner_out.deinit();
    var sup_out = try asm6564.assemble(testing.allocator, sup_src, null);
    defer sup_out.deinit();
    m.load(0, spinner_out.origin, spinner_out.code);
    m.load(0, sup_out.origin, sup_out.code);
    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 3,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.linkSupervisor(0, 1, 0, ring.slot_cq);
    m.setWatchdog(0, 1, 300);
    try m.spawn(0, 1, 0x1200, 0x3800, 0);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    try testing.expectEqual(machine.StopReason.faulted, try m.run());
    const spinner = &m.cores[0].contexts[1];
    try testing.expectEqual(machine.CtxState.faulted, spinner.state);
    try testing.expectEqual(machine.Fault.watchdog, spinner.fault);
    try testing.expectEqual(@as(u64, 1), m.stats.watchdog_trips);
    // The supervisor received the obituary as an ordinary completion record.
    const ram = m.cores[0].ram;
    const w0 = std.mem.readInt(u64, ram[0x2280 - machine.ram_base ..][0..8], .little);
    const c = ring.Completion.fromWords(w0, std.mem.readInt(u64, ram[0x2288 - machine.ram_base ..][0..8], .little));
    try testing.expectEqual(ring.Tag.exit, c.tag);
    try testing.expectEqual(ring.Status.fault, c.status);
    try testing.expectEqual(@intFromEnum(machine.Fault.watchdog), c.byte_count);
    try testing.expectEqual(@as(u64, 1), c.cookie);
}

test "WDEX: a declared burst outlives the base budget; the declaration dies at the park" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    // Two identical ~400-cycle spins under a 300-cycle base budget. The
    // first is declared (WDEX ##1000) and survives; the YLD parks, the
    // declaration resets to base, and the undeclared second spin trips.
    try assembleInto(&m, 0,
        \\        .org $1000
        \\        WDEX ##1000
        \\        LDX #100
        \\sp1:    DEX
        \\        BNE sp1
        \\        YLD
        \\sp2:    LDX #100
        \\sp3:    DEX
        \\        BNE sp3
        \\        HLT
    );
    m.setWatchdog(0, 0, 300);
    m.setWdexCeiling(0, 0, 2000);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.faulted, try m.run());
    const ctx = &m.cores[0].contexts[0];
    try testing.expectEqual(machine.Fault.watchdog, ctx.fault);
    try testing.expectEqual(@as(u64, 1), m.stats.watchdog_trips);
    // The trip happened in the SECOND spin — the declared one ran to term.
    try testing.expect(ctx.fault_addr >= 0x1010);
}

test "WDEX above the ceiling faults: asking is not receiving" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    try assembleInto(&m, 0,
        \\        .org $1000
        \\        WDEX ##5000
        \\        HLT
    );
    m.setWatchdog(0, 0, 300);
    m.setWdexCeiling(0, 0, 1000);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.faulted, try m.run());
    const ctx = &m.cores[0].contexts[0];
    try testing.expectEqual(machine.Fault.wdex_ceiling, ctx.fault);
    try testing.expectEqual(@as(u64, 0), m.stats.watchdog_trips);
}

test "WDEX: a second declaration replaces, and ##0 cancels back to base" {
    // Replace: ##1000 then ##50 — if the first survived, the 400-cycle
    // spin would pass; the replacement budget of 50 trips it.
    {
        var m = try Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 1,
            .ram_size = 0x4000,
        });
        defer m.deinit();
        try assembleInto(&m, 0,
            \\        .org $1000
            \\        WDEX ##1000
            \\        WDEX ##50
            \\        LDX #100
            \\sp:     DEX
            \\        BNE sp
            \\        HLT
        );
        m.setWatchdog(0, 0, 300);
        m.setWdexCeiling(0, 0, 1000);
        try m.spawn(0, 0, 0x1000, 0x3000, 0);
        try testing.expectEqual(machine.StopReason.faulted, try m.run());
        try testing.expectEqual(machine.Fault.watchdog, m.cores[0].contexts[0].fault);
    }
    // Cancel: declare ##1000, spin ~200, cancel — the base budget is
    // measured from burst start, so the next ~200 cycles cross 300.
    {
        var m = try Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 1,
            .ram_size = 0x4000,
        });
        defer m.deinit();
        try assembleInto(&m, 0,
            \\        .org $1000
            \\        WDEX ##1000
            \\        LDX #50
            \\c1:     DEX
            \\        BNE c1
            \\        WDEX ##0
            \\        LDX #50
            \\c2:     DEX
            \\        BNE c2
            \\        HLT
        );
        m.setWatchdog(0, 0, 300);
        m.setWdexCeiling(0, 0, 1000);
        try m.spawn(0, 0, 0x1000, 0x3000, 0);
        try testing.expectEqual(machine.StopReason.faulted, try m.run());
        try testing.expectEqual(machine.Fault.watchdog, m.cores[0].contexts[0].fault);
    }
}

fn resultAt(m: *Machine, addr: u64) u64 {
    return std.mem.readInt(u64, m.cores[0].ram[addr - machine.ram_base ..][0..8], .little);
}

test "Tier 0 FP: bit-exact arithmetic — 0.1 + 0.2 is famously $3FD3333333333334" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    try assembleInto(&m, 0,
        \\        .org $1000
        \\        LDA ##$3FB999999999999A   ; 0.1
        \\        FADD ##$3FC999999999999A  ; + 0.2
        \\        STA !$2280                ; the famous sum
        \\        FSUB ##$3FD3333333333333  ; - 0.3
        \\        STA !$2288                ; the residue, exact
        \\        LDA ##$4000000000000000   ; 2.0
        \\        FSQRT
        \\        STA !$2290
        \\        LDA ##$3FF0000000000000   ; 1.0
        \\        FDIV ##$4008000000000000  ; / 3.0
        \\        STA !$2298
        \\        FMUL ##$4008000000000000  ; * 3.0: RNE brings it home
        \\        STA !$22A0
        \\        HLT
    );
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    try testing.expectEqual(@as(u64, 0x3FD3333333333334), resultAt(&m, 0x2280));
    try testing.expectEqual(@as(u64, 0x3C90000000000000), resultAt(&m, 0x2288));
    try testing.expectEqual(@as(u64, 0x3FF6A09E667F3BCD), resultAt(&m, 0x2290));
    try testing.expectEqual(@as(u64, 0x3FD5555555555555), resultAt(&m, 0x2298));
    try testing.expectEqual(@as(u64, 0x3FF0000000000000), resultAt(&m, 0x22A0));
}

test "Tier 0 FP: FCMP flag vocabulary, FTOI truncation and saturation, ITOF" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    try assembleInto(&m, 0,
        \\        .org $1000
        \\        LDA ##$4004000000000000   ; 2.5
        \\        FCMP ##$4004000000000000  ; equal: Z
        \\        BNE bad
        \\        FCMP ##$4008000000000000  ; vs 3.0 — less: N, no C
        \\        BPL bad
        \\        BCS bad
        \\        FCMP ##$3FF0000000000000  ; vs 1.0 — greater: C, no Z/N
        \\        BCC bad
        \\        BEQ bad
        \\        BMI bad
        \\        FCMP ##$7FF8000000000000  ; vs NaN — unordered: V alone
        \\        BVC bad
        \\        BEQ bad
        \\        BMI bad
        \\        BCS bad
        \\        FTOI                      ; 2.5 truncates toward zero
        \\        BVS bad
        \\        STA !$2280                ; 2
        \\        LDA ##$C004000000000000   ; -2.5
        \\        FTOI
        \\        BVS bad
        \\        STA !$2288                ; -2, toward zero
        \\        LDA ##$7FF8000000000000   ; NaN
        \\        FTOI
        \\        BVC bad
        \\        STA !$2290                ; 0
        \\        LDA ##$7E37E43C8800759C   ; 1e300
        \\        FTOI
        \\        BVC bad
        \\        STA !$2298                ; saturated to maxInt
        \\        LDA ##$FFFFFFFFFFFFFFF9   ; -7
        \\        ITOF
        \\        BPL bad                   ; result flags speak FP: N = sign
        \\        STA !$22A0                ; -7.0
        \\        HLT
        \\bad:    BRK
    );
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    try testing.expectEqual(@as(u64, 2), resultAt(&m, 0x2280));
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -2))), resultAt(&m, 0x2288));
    try testing.expectEqual(@as(u64, 0), resultAt(&m, 0x2290));
    try testing.expectEqual(@as(u64, std.math.maxInt(i64)), resultAt(&m, 0x2298));
    try testing.expectEqual(@as(u64, 0xC01C000000000000), resultAt(&m, 0x22A0));
}

test "Tier 0 FP: FP32 narrows on store, widens on load — rounding is visible once" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    try assembleInto(&m, 0,
        \\        .org $1000
        \\        LDA ##$3FB999999999999A   ; 0.1 (f64)
        \\        FSTS !$2280               ; f32: $3DCCCCCD
        \\        FLDS !$2280
        \\        STA !$2290                ; f32(0.1) widened — not 0.1
        \\        LDA ##$3FF8000000000000   ; 1.5 survives the trip exactly
        \\        FSTS !$2298
        \\        FLDS !$2298
        \\        STA !$22A0
        \\        HLT
    );
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    const f32bits = std.mem.readInt(u32, m.cores[0].ram[0x2280 - machine.ram_base ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x3DCCCCCD), f32bits);
    try testing.expectEqual(@as(u64, 0x3FB99999A0000000), resultAt(&m, 0x2290));
    try testing.expectEqual(@as(u64, 0x3FF8000000000000), resultAt(&m, 0x22A0));
}

test "joe: the loader runs pingpong.joe from its system block, sequence-checked" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/pingpong.joe");
    // The same gauntlet the hand-written protocol runs: 25% loss with
    // duplication, and then deep loss. joe cannot say "transport ack" —
    // the end-to-end protocol the compiler emits must carry it anyway.
    for ([_]u16{ 1024, 3000 }) |loss| {
        var o = try joe_run.simulate(testing.allocator, src, .{ .loss_ppm4k = loss });
        defer o.deinit();
        try testing.expectEqual(machine.CtxState.halted, o.instance("pinger").?.state);
        try testing.expectEqual(machine.CtxState.parked, o.instance("ponger").?.state);
        try testing.expectEqual(@as(u64, 8), o.varOf("pinger", "seq").?);
    }
}

test "joe: the loader is deterministic, seed for seed" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/pingpong.joe");
    var a = try joe_run.simulate(testing.allocator, src, .{ .seed = 0xBEEF });
    defer a.deinit();
    var b = try joe_run.simulate(testing.allocator, src, .{ .seed = 0xBEEF });
    defer b.deinit();
    try testing.expectEqual(a.cycles, b.cycles);
    try testing.expectEqual(a.stats.instructions, b.stats.instructions);
    try testing.expectEqual(a.stats.lost, b.stats.lost);
}

test "joe: two instances share a core in separate blocks — placement is data" {
    const joe_run = @import("joe_run.zig");
    // Same program, both actors forced onto core 0 as two contexts:
    // the loader gives each its own $1000 block, so nothing collides
    // and the protocol still completes.
    const base = @embedFile("programs/joe/pingpong.joe");
    const src = try std.mem.concat(testing.allocator, u8, &.{
        base[0 .. std.mem.indexOf(u8, base, "system {").?],
        \\system {
        \\    pinger = Pinger(ponger, 8) on 0
        \\    ponger = Ponger(pinger) on 0
        \\}
        ,
    });
    defer testing.allocator.free(src);
    var o = try joe_run.simulate(testing.allocator, src, .{});
    defer o.deinit();
    try testing.expectEqual(machine.CtxState.halted, o.instance("pinger").?.state);
    try testing.expectEqual(@as(u64, 8), o.varOf("pinger", "seq").?);
    try testing.expectEqual(@as(u8, 0), o.instance("pinger").?.ctx);
    try testing.expectEqual(@as(u8, 1), o.instance("ponger").?.ctx);
}

test "joe: the ring turns — 8 instances from one system block, token comes home" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/ring.joe");
    var o = try joe_run.simulate(testing.allocator, src, .{});
    defer o.deinit();
    try testing.expectEqual(machine.CtxState.halted, o.instance("n0").?.state);
    try testing.expectEqual(@as(u64, 0), o.varOf("n0", "remaining").?);
    for (1..8) |k| {
        var name_buf: [4]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "n{d}", .{k});
        try testing.expectEqual(machine.CtxState.parked, o.instance(name).?.state);
    }
    // Handoff item 4, the pre-registered claim, answered: naive v1
    // codegen paid 110 cy/pass; the prediction said the collapsed-
    // register convention would hold it under 70; the burst-liveness
    // codegen measures 55 — under the hand-written ring's 60. The
    // convention beat the heroics. The guard holds the prediction, not
    // the achievement, so honest codegen changes have room to breathe.
    const cy_per_pass = o.cycles / 800;
    try testing.expect(cy_per_pass < 70);
}

// A2 harness: compile one actor, run it to completion on a bare machine,
// hand back the machine for near-page inspection. The caller deinits both.
fn runBareActor(src: []const u8, actor: []const u8, r: *joe.Result) !machine.Machine {
    var diag = joe.Diagnostic{};
    r.* = joe.compile(testing.allocator, src, actor, .{}, &diag) catch |err| {
        std.debug.print("joe {s}: line {d}: {s}\n", .{ actor, diag.line, diag.message });
        return err;
    };
    errdefer r.deinit();
    var adiag = asm6564.Diagnostic{};
    var out = try asm6564.assemble(testing.allocator, r.asm_text, &adiag);
    defer out.deinit();
    var m = try machine.Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .scorch_parks = true, // A2.7: everything runs under scorch
    });
    errdefer m.deinit();
    m.load(0, out.origin, out.code);
    try m.spawn(0, 0, out.origin, 0x8000, 0);
    _ = try m.run();
    return m;
}

fn bufOf(r: *const joe.Result, name: []const u8) *const joe.BufOut {
    for (r.bufs) |*b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    unreachable;
}

test "A2: pack — the machine and the host half agree on every byte" {
    const struple = @import("struple.zig");
    const src =
        \\actor P() {
        \\    var key buf [64]u8
        \\    var k2 buf [64]u8
        \\    var id u64 = 12345
        \\    var zero u64 = 0
        \\    var big u64 = 18446744073709551615
        \\    pack key, ("users", id, "profile")
        \\    pack key, ("users", id, "profile")
        \\    pack k2, (7, zero, big, "x")
        \\}
    ;
    var r: joe.Result = undefined;
    var m = try runBareActor(src, "P", &r);
    defer m.deinit();
    defer r.deinit();

    // the oracle: the host half of implementation #13
    var p = struple.Packer.init(testing.allocator);
    defer p.deinit();
    try p.appendString("users");
    try p.appendUint(12345);
    try p.appendString("profile");

    const near = &m.cores[0].contexts[0].near;
    const key = bufOf(&r, "key");
    const got_len = std.mem.readInt(u64, near[key.len_slot..][0..8], .little);
    try testing.expectEqual(p.bytes().len, got_len);
    try testing.expectEqualSlices(u8, p.bytes(), near[key.data..][0..p.bytes().len]);

    var p2 = struple.Packer.init(testing.allocator);
    defer p2.deinit();
    try p2.appendUint(7);
    try p2.appendUint(0);
    try p2.appendUint(18446744073709551615);
    try p2.appendString("x");
    const k2 = bufOf(&r, "k2");
    const got2 = std.mem.readInt(u64, near[k2.len_slot..][0..8], .little);
    try testing.expectEqual(p2.bytes().len, got2);
    try testing.expectEqualSlices(u8, p2.bytes(), near[k2.data..][0..p2.bytes().len]);
}

test "A2.7: skip is total on the machine — the full corpus, under scorch" {
    // The machine half of struple #13: `.count()` compiles to the total
    // element walk, and every corpus vector — including big ints,
    // decimal, map and set, which joe cannot decode — must walk to the
    // exact end with the host reader's element count. Registers poisoned
    // at every park, per the amendment's conformance clause.
    const struple = @import("struple.zig");
    const src =
        \\actor Skipper() {
        \\    var key buf [280]u8
        \\    var n u64 = 0
        \\    n = key.count()
        \\}
    ;
    var r: joe.Result = undefined;
    var diag = joe.Diagnostic{};
    r = try joe.compile(testing.allocator, src, "Skipper", .{}, &diag);
    defer r.deinit();
    var adiag = asm6564.Diagnostic{};
    var out = try asm6564.assemble(testing.allocator, r.asm_text, &adiag);
    defer out.deinit();
    const key = bufOf(&r, "key");
    const n_off = for (r.vars) |v| {
        if (std.mem.eql(u8, v.name, "n")) break v.off;
    } else unreachable;

    const corpus = @embedFile("struple_vectors.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, corpus, .{});
    defer parsed.deinit();
    var walked: usize = 0;
    for (parsed.value.array.items) |entry| {
        const hex = entry.object.get("bytes").?.string;
        const want = try testing.allocator.alloc(u8, hex.len / 2);
        defer testing.allocator.free(want);
        _ = try std.fmt.hexToBytes(want, hex);

        var hr = struple.Reader.init(want);
        var host_n: u64 = 0;
        while (!hr.done()) {
            _ = try hr.skipRaw();
            host_n += 1;
        }

        var m = try machine.Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 1,
            .scorch_parks = true,
        });
        defer m.deinit();
        m.load(0, out.origin, out.code);
        const near = &m.cores[0].contexts[0].near;
        @memcpy(near[key.data..][0..want.len], want);
        std.mem.writeInt(u64, near[key.len_slot..][0..8], want.len, .little);
        try m.spawn(0, 0, out.origin, 0x8000, 0);
        _ = try m.run();
        try testing.expectEqual(machine.CtxState.halted, m.cores[0].contexts[0].state);
        try testing.expectEqual(host_n, std.mem.readInt(u64, near[n_off..][0..8], .little));
        walked += 1;
    }
    try testing.expect(walked >= 60); // the whole corpus, not a sample
}

test "A2.7: the machine's int encoder reproduces the corpus vectors" {
    const struple = @import("struple.zig");
    const src =
        \\actor PackOne(v u64) {
        \\    var key buf [32]u8
        \\    pack key, (v)
        \\}
    ;
    var r: joe.Result = undefined;
    var diag = joe.Diagnostic{};
    r = try joe.compile(testing.allocator, src, "PackOne", .{}, &diag);
    defer r.deinit();
    var adiag = asm6564.Diagnostic{};
    var out = try asm6564.assemble(testing.allocator, r.asm_text, &adiag);
    defer out.deinit();
    const key = bufOf(&r, "key");
    const v_off = r.params[0].off;

    const corpus = @embedFile("struple_vectors.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, corpus, .{});
    defer parsed.deinit();
    var packed_n: usize = 0;
    for (parsed.value.array.items) |entry| {
        const hex = entry.object.get("bytes").?.string;
        const want = try testing.allocator.alloc(u8, hex.len / 2);
        defer testing.allocator.free(want);
        _ = try std.fmt.hexToBytes(want, hex);
        // joe utters unsigned ints: single-element non-negative ≤ u64
        var hr = struple.Reader.init(want);
        const el = (hr.next() catch continue) orelse continue;
        if (el != .int or !hr.done()) continue;
        if (el.int < 0 or el.int > std.math.maxInt(u64)) continue;

        var m = try machine.Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 1,
            .scorch_parks = true,
        });
        defer m.deinit();
        m.load(0, out.origin, out.code);
        const near = &m.cores[0].contexts[0].near;
        std.mem.writeInt(u64, near[v_off..][0..8], @intCast(el.int), .little);
        try m.spawn(0, 0, out.origin, 0x8000, 0);
        _ = try m.run();
        const got_len = std.mem.readInt(u64, near[key.len_slot..][0..8], .little);
        try testing.expectEqual(want.len, got_len);
        try testing.expectEqualSlices(u8, want, near[key.data..][0..want.len]);
        packed_n += 1;
    }
    try testing.expect(packed_n >= 6);
}

test "A2.4: keys.joe — dispatch on structured keys is memcmp, scorched too" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/keys.joe");
    for ([_]bool{ false, true }) |burnt| {
        var o = try joe_run.simulate(testing.allocator, src, .{
            .loss_ppm4k = 0,
            .dup_ppm4k = 0,
            .scorch = burnt,
        });
        defer o.deinit();
        // three keys: one bound with a rest view, one exact, one that
        // falls through both patterns to the wildcard
        try testing.expectEqual(@as(u64, 1), o.varOf("router", "users_seen").?);
        try testing.expectEqual(@as(u64, 42), o.varOf("router", "user_id").?);
        try testing.expectEqual(@as(u64, 9), o.varOf("router", "rest_len").?);
        try testing.expectEqual(@as(u64, 1), o.varOf("router", "posts_seen").?);
        try testing.expectEqual(@as(u64, 7), o.varOf("router", "post_id").?);
        try testing.expectEqual(@as(u64, 1), o.varOf("router", "missed").?);
        try testing.expectEqual(@as(u64, 3), o.varOf("asker", "step").?);
    }
}

// ── Tier 1 vectors (item 5) ─────────────────────────────────────────────

fn vecMachine(src: []const u8) !Machine {
    var m = try Machine.init(testing.allocator, .{ .cores = 1, .contexts_per_core = 1 });
    errdefer m.deinit();
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x8000, 0);
    _ = try m.run();
    try testing.expectEqual(machine.CtxState.halted, m.cores[0].contexts[0].state);
    return m;
}

test "tier 1: lanewise RNE is bit-exact and the reduction tree is THE tree" {
    // 0.1 + 0.2 in every lane — the same bits Tier 0 proved, ×8. Then a
    // reduction whose value DEPENDS on the spec'd shape: with lane 0 =
    // 1e16 and seven 1.0s, the pairwise tree yields 1e16+6 while a
    // sequential fold ties-to-even into 1e16 exactly. The machine must
    // produce the tree's bits — reduction order is part of the contract.
    const src =
        \\        .org $1000
        \\        LDA ##$3FB999999999999A
        \\        VBCA 0
        \\        LDA ##$3FC999999999999A
        \\        VBCA 1
        \\        VFADD 0, 1
        \\        LDX ##$4000
        \\        VST 0
        \\        LDX ##$5000
        \\        VLD 2
        \\        VRADD 2
        \\        STA !$4040
        \\        HLT
    ;
    var m = try Machine.init(testing.allocator, .{ .cores = 1, .contexts_per_core = 1 });
    defer m.deinit();
    // stage the reduction input at $5000: [1e16, 1, 1, 1, 1, 1, 1, 1]
    const lanes: [8]f64 = .{ 1e16, 1, 1, 1, 1, 1, 1, 1 };
    var blob: [64]u8 = undefined;
    for (lanes, 0..) |v, i|
        std.mem.writeInt(u64, blob[i * 8 ..][0..8], @bitCast(v), .little);
    m.load(0, 0x5000, &blob);
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x8000, 0);
    _ = try m.run();
    const ram = m.cores[0].ram;
    for (0..8) |i| {
        const lane = std.mem.readInt(u64, ram[0x4000 - machine.ram_base + i * 8 ..][0..8], .little);
        try testing.expectEqual(@as(u64, 0x3FD3333333333334), lane);
    }
    // host mirrors: the tree, and the fold it must NOT be
    const tree = ((lanes[0] + lanes[1]) + (lanes[2] + lanes[3])) +
        ((lanes[4] + lanes[5]) + (lanes[6] + lanes[7]));
    var seq: f64 = 0;
    for (lanes) |v| seq += v;
    const got: f64 = @bitCast(std.mem.readInt(u64, ram[0x4040 - machine.ram_base ..][0..8], .little));
    try testing.expectEqual(@as(u64, @bitCast(tree)), @as(u64, @bitCast(got)));
    try testing.expect(@as(u64, @bitCast(tree)) != @as(u64, @bitCast(seq)));
}

test "tier 1: permute, integer lanes, and the reduction extremes" {
    const src =
        \\        .org $1000
        \\        LDX ##$5000
        \\        VLD 0
        \\        LDA ##$0001020304050607
        \\        VPERM 1, 0
        \\        LDX ##$4000
        \\        VST 1
        \\        LDA #3
        \\        VBCA 2
        \\        VADD 2, 2
        \\        LDX ##$4040
        \\        VST 2
        \\        VRMAX 0
        \\        STA !$4080
        \\        VRMIN 0
        \\        STA !$4088
        \\        HLT
    ;
    var m = try Machine.init(testing.allocator, .{ .cores = 1, .contexts_per_core = 1 });
    defer m.deinit();
    const lanes: [8]f64 = .{ 4, -8, 15, 16, 23, 42, -0.5, 7 };
    var blob: [64]u8 = undefined;
    for (lanes, 0..) |v, i|
        std.mem.writeInt(u64, blob[i * 8 ..][0..8], @bitCast(v), .little);
    m.load(0, 0x5000, &blob);
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x8000, 0);
    _ = try m.run();
    const ram = m.cores[0].ram;
    // permute: A's byte i names the source lane — 07..00 reverses
    for (0..8) |i| {
        const lane: f64 = @bitCast(std.mem.readInt(u64, ram[0x4000 - machine.ram_base + i * 8 ..][0..8], .little));
        try testing.expectEqual(@as(u64, @bitCast(lanes[7 - i])), @as(u64, @bitCast(lane)));
    }
    for (0..8) |i| {
        try testing.expectEqual(@as(u64, 6), std.mem.readInt(u64, ram[0x4040 - machine.ram_base + i * 8 ..][0..8], .little));
    }
    const mx: f64 = @bitCast(std.mem.readInt(u64, ram[0x4080 - machine.ram_base ..][0..8], .little));
    const mn: f64 = @bitCast(std.mem.readInt(u64, ram[0x4088 - machine.ram_base ..][0..8], .little));
    try testing.expectEqual(@as(f64, 42), mx);
    try testing.expectEqual(@as(f64, -8), mn);
}

test "tier 1: V registers are volatile across parks — scorch says so" {
    // Fill V0, yield (a park), then store it. Under scorch every lane
    // comes back as the poison pattern: nothing wide survives a park,
    // by the same convention that governs A. Without scorch the bits
    // happen to survive on an idle core — which is exactly why scorch
    // exists: the convention is the contract, not the luck.
    const src =
        \\        .org $1000
        \\        LDA ##$AAAAAAAAAAAAAAAA
        \\        VBCA 0
        \\        YLD
        \\        LDX ##$4000
        \\        VST 0
        \\        HLT
    ;
    for ([_]bool{ false, true }) |burnt| {
        var m = try Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 1,
            .scorch_parks = burnt,
        });
        defer m.deinit();
        try assembleInto(&m, 0, src);
        try m.spawn(0, 0, 0x1000, 0x8000, 0);
        _ = try m.run();
        const want: u64 = if (burnt) machine.scorch_pattern else 0xAAAAAAAAAAAAAAAA;
        for (0..8) |i| {
            const lane = std.mem.readInt(u64, m.cores[0].ram[0x4000 - machine.ram_base + i * 8 ..][0..8], .little);
            try testing.expectEqual(want, lane);
        }
    }
}

test "tier 1: a 256-element dot product, bit-exact against the host mirror" {
    const vector_src =
        \\        .org $1000
        \\        LDA ##$4000
        \\        STA $800
        \\        LDA ##$4800
        \\        STA $808
        \\        LDA #32
        \\        STA $810
        \\        LDA #0
        \\        VBCA 2
        \\loop:   LDX $800
        \\        VLD 0
        \\        LDX $808
        \\        VLD 1
        \\        VFMUL 0, 1
        \\        VFADD 2, 0
        \\        LDA $800
        \\        CLC
        \\        ADC #64
        \\        STA $800
        \\        LDA $808
        \\        CLC
        \\        ADC #64
        \\        STA $808
        \\        DEC $810
        \\        LDA $810
        \\        BNE loop
        \\        VRADD 2
        \\        STA !$5800
        \\        HLT
    ;
    const scalar_src =
        \\        .org $1000
        \\        LDA ##$4000
        \\        STA $800
        \\        LDA ##$4800
        \\        STA $808
        \\        LDA ##256
        \\        STA $810
        \\        LDA #0
        \\        STA $818
        \\sloop:  LDA ($800)
        \\        FMUL ($808)
        \\        FADD $818
        \\        STA $818
        \\        LDA $800
        \\        CLC
        \\        ADC #8
        \\        STA $800
        \\        LDA $808
        \\        CLC
        \\        ADC #8
        \\        STA $808
        \\        DEC $810
        \\        LDA $810
        \\        BNE sloop
        \\        LDA $818
        \\        STA !$5800
        \\        HLT
    ;
    // deterministic data with real rounding activity
    var a: [256]f64 = undefined;
    var b: [256]f64 = undefined;
    for (0..256) |i| {
        a[i] = 0.1 * @as(f64, @floatFromInt(i)) + 1.0;
        b[i] = 1.0 / (0.3 * @as(f64, @floatFromInt(i)) + 2.0);
    }
    var blob_a: [2048]u8 = undefined;
    var blob_b: [2048]u8 = undefined;
    for (0..256) |i| {
        std.mem.writeInt(u64, blob_a[i * 8 ..][0..8], @bitCast(a[i]), .little);
        std.mem.writeInt(u64, blob_b[i * 8 ..][0..8], @bitCast(b[i]), .little);
    }
    var cycles: [2]u64 = undefined;
    var results: [2]u64 = undefined;
    for ([_][]const u8{ vector_src, scalar_src }, 0..) |src, k| {
        var m = try Machine.init(testing.allocator, .{ .cores = 1, .contexts_per_core = 1 });
        defer m.deinit();
        m.load(0, 0x4000, &blob_a);
        m.load(0, 0x4800, &blob_b);
        try assembleInto(&m, 0, src);
        try m.spawn(0, 0, 0x1000, 0x8000, 0);
        _ = try m.run();
        try testing.expectEqual(machine.CtxState.halted, m.cores[0].contexts[0].state);
        results[k] = std.mem.readInt(u64, m.cores[0].ram[0x5800 - machine.ram_base ..][0..8], .little);
        cycles[k] = m.cores[0].clock;
    }
    // vector mirror: per-lane sequential accumulation, then the tree
    var acc: [8]f64 = @splat(0.0);
    for (0..32) |c| {
        for (0..8) |j| acc[j] += a[c * 8 + j] * b[c * 8 + j];
    }
    const tree = ((acc[0] + acc[1]) + (acc[2] + acc[3])) +
        ((acc[4] + acc[5]) + (acc[6] + acc[7]));
    try testing.expectEqual(@as(u64, @bitCast(tree)), results[0]);
    // scalar mirror: plain sequential fold
    var seq: f64 = 0;
    for (0..256) |i| seq += a[i] * b[i];
    try testing.expectEqual(@as(u64, @bitCast(seq)), results[1]);
    // the two orders honestly differ in bits, and agree in value
    try testing.expect(results[0] != results[1]);
    try testing.expect(@abs(tree - seq) < 1e-9);
    // and the lanes pay: the vector loop beats scalar by a wide margin
    try testing.expect(cycles[0] * 4 < cycles[1]);
    std.debug.print("\n[tier1] dot256: vector {d} cy, scalar {d} cy ({d:.1}x)\n", .{
        cycles[0], cycles[1],
        @as(f64, @floatFromInt(cycles[1])) / @as(f64, @floatFromInt(cycles[0])),
    });
}

test "A1.4: vecmath.joe — SIMD is a data type with operators, bit-exact" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/vecmath.joe");
    var o = try joe_run.simulate(testing.allocator, src, .{});
    defer o.deinit();
    try testing.expectEqual(machine.CtxState.halted, o.instance("calc").?.state);
    // host mirror, op for op: lanewise (x*2)+1, then the spec'd tree
    var w: [8]f64 = undefined;
    for (0..8) |i| w[i] = (@as(f64, @floatFromInt(i + 1)) * 2.0) + 1.0;
    const tree = ((w[0] + w[1]) + (w[2] + w[3])) + ((w[4] + w[5]) + (w[6] + w[7]));
    try testing.expectEqual(@as(u64, @bitCast(tree)), o.varOf("calc", "sum").?);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 17.0))), o.varOf("calc", "top").?);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 3.0))), o.varOf("calc", "low").?);
    // permute([0×8]) broadcasts lane 0 — the sum proves the picks
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 8.0))), o.varOf("calc", "picked").?);
    // scalar float path: 1/3 to the bit, and FTOI's honest truncation
    const third: f64 = 1.0 / 3.0;
    try testing.expectEqual(@as(u64, @bitCast(third)), o.varOf("calc", "third").?);
    const scaled: f64 = third * 300.0;
    try testing.expectEqual(@as(u64, @intFromFloat(@trunc(scaled))), o.varOf("calc", "scaled").?);
    // float compares through FCMP's flags
    try testing.expectEqual(@as(u64, 1), o.varOf("calc", "flag").?);
}

// ── Item 6: registered regions + the matmul accelerator ─────────────────

// The driver program is IDENTICAL for both implementations: it grants a
// region and asks PTT slot 3 for a 4×4×4 matmul. The TEST decides which
// silicon sits behind slot 3 — §7.5 in one binding.
pub const matmul_asm =
    \\        .org $1000
    \\; rings: SQ $2400, CQ $2000, RX $2100 (cap 2, AUTO_REPOST, token $6564)
    \\        LDA ##$2400
    \\        STA $0
    \\        LDA ##$1000000002000
    \\        STA $8
    \\        LDA #0
    \\        STA $10
    \\        STA $18
    \\        LDA ##$2000
    \\        STA $20
    \\        LDA ##$1000000001004
    \\        STA $28
    \\        LDA #0
    \\        STA $30
    \\        STA $38
    \\        LDA ##$2100
    \\        STA $40
    \\        LDA ##$101000000002001
    \\        STA $48
    \\        LDA #0
    \\        STA $50
    \\        LDA ##$6564
    \\        STA $58
    \\        LDA ##$2200
    \\        STA !$2100
    \\        STA !$2118
    \\        LDA #64
    \\        STA !$2108
    \\        LDA #0
    \\        STA !$2110
    \\        LDA ##$2240
    \\        STA !$2120
    \\        STA !$2138
    \\        LDA #64
    \\        STA !$2128
    \\        LDA #0
    \\        STA !$2130
    \\        RECV 2
    \\        RECV 2
    \\; REGION descriptor, slot 8: base $6000, len $1000, token $1234
    \\        LDA ##$6000
    \\        STA $100
    \\        LDA ##$200000000000000
    \\        STA $108
    \\        LDA ##$1000
    \\        STA $110
    \\        LDA ##$1234
    \\        STA $118
    \\; the request (w0 reserved): slot 8, token, 4x4x4, A +0, B +$80, C +$100
    \\        LDA #0
    \\        STA !$2500
    \\        LDA #8
    \\        STA !$2508
    \\        LDA ##$1234
    \\        STA !$2510
    \\        LDA ##$400040004
    \\        STA !$2518
    \\        LDA #0
    \\        STA !$2520
    \\        LDA ##$80
    \\        STA !$2528
    \\        LDA ##$100
    \\        STA !$2530
    \\; grant-on-submit: one SQE to the accelerator behind PTT slot 3
    \\        LDA #1
    \\        STA !$2400
    \\        LDA ##$FF00030000000000
    \\        STA !$2408
    \\        LDA ##$2500
    \\        STA !$2410
    \\        LDA ##$100000038
    \\        STA !$2418
    \\        SEND 0
    \\wait:   LSTN 1
    \\        CQPOP 1
    \\        BEQ wait
    \\        STA $800
    \\        STX $808
    \\        AND #$FF
    \\        CMP #3
    \\        BNE wait
    \\        LDA ($808)
    \\        STA $810
    \\        HLT
;

fn accelMachine(kind: anytype, revoke_line: []const u8) !Machine {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .link = .{ .loss_ppm4k = 0, .dup_ppm4k = 0 },
    });
    errdefer m.deinit();
    try m.attachAccel(0xFF05, 0xACCE, kind);
    m.setPtt(0, 3, .{
        .prefix_hi = 0xfd65_6400_0000_0000,
        .prefix_lo = ring.PttEntry.loFrom(0xFF05, 0, 0),
        .rights = .{ .send = true },
        .token = 0xACCE,
    });
    // A[i][k] = i·4+k+1, B[k][j] = (k+1) + (j+1)/2 — real rounding work
    var blob: [256]u8 = undefined;
    for (0..4) |i| {
        for (0..4) |k| {
            const v: f64 = @floatFromInt(i * 4 + k + 1);
            std.mem.writeInt(u64, blob[(i * 4 + k) * 8 ..][0..8], @bitCast(v), .little);
        }
    }
    m.load(0, 0x6000, blob[0..128]);
    for (0..4) |k| {
        for (0..4) |j| {
            const v: f64 = @as(f64, @floatFromInt(k + 1)) + @as(f64, @floatFromInt(j + 1)) / 2.0;
            std.mem.writeInt(u64, blob[(k * 4 + j) * 8 ..][0..8], @bitCast(v), .little);
        }
    }
    m.load(0, 0x6080, blob[0..128]);
    // splice the (optional) revocation between SEND and the wait loop
    var src = std.ArrayList(u8).init(testing.allocator);
    defer src.deinit();
    const split = std.mem.indexOf(u8, matmul_asm, "wait:").?;
    try src.appendSlice(matmul_asm[0..split]);
    try src.appendSlice(revoke_line);
    try src.appendSlice(matmul_asm[split..]);
    try assembleInto(&m, 0, src.items);
    try m.spawn(0, 0, 0x1000, 0x8000, 0);
    _ = try m.run();
    return m;
}

fn matmulMirror() [16]f64 {
    var a: [4][4]f64 = undefined;
    var b: [4][4]f64 = undefined;
    for (0..4) |i| {
        for (0..4) |k| a[i][k] = @floatFromInt(i * 4 + k + 1);
    }
    for (0..4) |k| {
        for (0..4) |j| b[k][j] = @as(f64, @floatFromInt(k + 1)) + @as(f64, @floatFromInt(j + 1)) / 2.0;
    }
    var c: [16]f64 = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            var acc: f64 = 0;
            for (0..4) |k| acc += a[i][k] * b[k][j];
            c[i * 4 + j] = acc;
        }
    }
    return c;
}

test "item 6: the matmul completes through a granted region — both siliconsindistinguishable" {
    const mirror = matmulMirror();
    var pulls: [2]u64 = undefined;
    inline for (.{ .inproc, .remote }, 0..) |kind, ki| {
        var m = try accelMachine(kind, "");
        defer m.deinit();
        const ctx = &m.cores[0].contexts[0];
        try testing.expectEqual(machine.CtxState.halted, ctx.state);
        // completion said ok: the architected tag, status clear above it
        try testing.expectEqual(@as(u64, 0x6772), std.mem.readInt(u64, ctx.near[0x810..][0..8], .little));
        // C matches the declared-deterministic contract, bit for bit
        for (0..16) |i| {
            const got = std.mem.readInt(u64, m.cores[0].ram[0x6100 - machine.ram_base + i * 8 ..][0..8], .little);
            try testing.expectEqual(@as(u64, @bitCast(mirror[i])), got);
        }
        // the release fence: OWNED is clear again
        const w1 = std.mem.readInt(u64, ctx.near[0x108..][0..8], .little);
        try testing.expectEqual(@as(u64, 0), (w1 >> 56) & ring.desc_flag_owned);
        pulls[ki] = m.stats.accel_pulls;
    }
    // same bytes; only the window traffic (and the wall clock, which a
    // parked core doesn't pay) can tell the implementations apart
    try testing.expectEqual(@as(u64, 0), pulls[0]);
    try testing.expect(pulls[1] > 0);
}

test "item 6: revocation between grant and completion — reject, never a scribble" {
    // The transport ack IS the acceptance: wait for it (tag 2), then
    // kill the token while the remote implementation is still pulling.
    // Its late DMA re-checks the live descriptor and reject-completes.
    var m = try accelMachine(.remote,
        \\wack:   LSTN 1
        \\        CQPOP 1
        \\        BEQ wack
        \\        AND #$FF
        \\        CMP #2
        \\        BNE wack
        \\        LDA #0
        \\        STA $118
        \\
    );
    defer m.deinit();
    const ctx = &m.cores[0].contexts[0];
    try testing.expectEqual(machine.CtxState.halted, ctx.state);
    // the completion arrived — as a reject (status above the tag)
    try testing.expectEqual(@as(u64, 0x16772), std.mem.readInt(u64, ctx.near[0x810..][0..8], .little));
    // and C was never touched
    for (0..16) |i| {
        const got = std.mem.readInt(u64, m.cores[0].ram[0x6100 - machine.ram_base + i * 8 ..][0..8], .little);
        try testing.expectEqual(@as(u64, 0), got);
    }
    // the fence still fired: OWNED is clear
    const w1 = std.mem.readInt(u64, ctx.near[0x108..][0..8], .little);
    try testing.expectEqual(@as(u64, 0), (w1 >> 56) & ring.desc_flag_owned);
}

test "item 6: saturation is backpressure — a busy accelerator rejects, corrupts nothing" {
    // Two asks back-to-back at a depth-one unit (the remote polyfill,
    // whose long flight guarantees the overlap): the second is
    // reject-completed at the sender, the first completes exactly.
    var m = try accelMachine(.remote,
        \\        LDA #1
        \\        STA !$2400
        \\        LDA ##$FF00030000000000
        \\        STA !$2408
        \\        LDA ##$2500
        \\        STA !$2410
        \\        LDA ##$100000030
        \\        STA !$2418
        \\        SEND 0
        \\
    );
    defer m.deinit();
    const ctx = &m.cores[0].contexts[0];
    try testing.expectEqual(machine.CtxState.halted, ctx.state);
    try testing.expect(m.stats.rejects >= 1);
    try testing.expectEqual(@as(u64, 0x6772), std.mem.readInt(u64, ctx.near[0x810..][0..8], .little));
    const mirror = matmulMirror();
    for (0..16) |i| {
        const got = std.mem.readInt(u64, m.cores[0].ram[0x6100 - machine.ram_base + i * 8 ..][0..8], .little);
        try testing.expectEqual(@as(u64, @bitCast(mirror[i])), got);
    }
}

test "item 7: the MAC re-trial — the store's twelve comparators, one routine" {
    // The deferred measurement, re-run on a corpus with real reuse:
    // store.joe compares four bufs against one key field from twelve
    // sites. With use_mac the sites collapse to a four-instruction call
    // through MACTAB slot 0, each burst re-establishes SP (the tax the
    // collapse removed), and the outcomes must not move a bit — under
    // scorch, naturally, since MAC linkage is stack state inside a
    // burst and nothing survives the parks.
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/store.joe");
    var bytes: [2]usize = undefined;
    var cycles: [2]u64 = undefined;
    var calls: [2]u64 = undefined;
    for ([_]bool{ false, true }, 0..) |mac, k| {
        var o = try joe_run.simulate(testing.allocator, src, .{
            .loss_ppm4k = 0,
            .dup_ppm4k = 0,
            .use_mac = mac,
            .scorch = true,
        });
        defer o.deinit();
        try testing.expectEqual(@as(u64, 4343), o.varOf("client", "got_hs").?);
        try testing.expectEqual(@as(u64, 111), o.varOf("client", "got_p1").?);
        try testing.expectEqual(@as(u64, 2), o.varOf("client", "misses").?);
        try testing.expectEqual(@as(u64, 1), o.varOf("store", "used").?);
        bytes[k] = o.instance("store").?.code_bytes;
        cycles[k] = o.cycles;
        calls[k] = o.stats.macro_calls;
    }
    try testing.expectEqual(@as(u64, 0), calls[0]);
    try testing.expect(calls[1] > 0);
    try testing.expect(bytes[1] < bytes[0]);
    std.debug.print("\n[item7] store: {d} B / {d} cy inline  →  {d} B / {d} cy MAC ({d} calls, {d:.1}% code)\n", .{
        bytes[0], cycles[0], bytes[1], cycles[1], calls[1],
        @as(f64, @floatFromInt(bytes[1])) * 100.0 / @as(f64, @floatFromInt(bytes[0])),
    });
}

test "item 6b: matmul.joe — grant, type-state, rebind; both silicons, same bits" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/matmul.joe");
    // the same program against the remote polyfill: one name changes
    var remote_src_buf: [8192]u8 = undefined;
    const remote_src = blk: {
        const idx = std.mem.indexOf(u8, src, "Matmul()").?;
        const n = (try std.fmt.bufPrint(&remote_src_buf, "{s}MatmulRemote(){s}", .{
            src[0..idx], src[idx + 8 ..],
        })).len;
        break :blk remote_src_buf[0..n];
    };
    var sums: [2]u64 = undefined;
    for ([_][]const u8{ src, remote_src }, 0..) |source, k| {
        var o = try joe_run.simulate(testing.allocator, source, .{
            .loss_ppm4k = 0,
            .dup_ppm4k = 0,
            .scorch = true,
        });
        defer o.deinit();
        try testing.expectEqual(@as(u64, 1), o.varOf("s", "status").?);
        sums[k] = o.varOf("s", "checksum").?;
        // C[0,0] = 50, C[3,3] = 329 — the declared-deterministic mirror
        try testing.expectEqual(@as(u64, @bitCast(@as(f64, 379.0))), sums[k]);
    }
    try testing.expectEqual(sums[0], sums[1]);
}

test "item 6b: a granted region is unreachable by type — §6.2 at compile time" {
    // touching the region after the grant, in the same handler: refused
    const bad1 =
        \\message Mul { r grant, dims u64, offa u64, offb u64, offc u64 }
        \\actor A(tpu addr) {
        \\    var frame region [96]f64
        \\    send tpu, Mul{grant frame, 1, 0, 8, 16}
        \\    frame[0] = 1.0
        \\    serve { case done(frame): quiesce }
        \\}
    ;
    // touching it from a handler that neither grants nor rebinds: refused
    const bad2 =
        \\message Mul { r grant, dims u64, offa u64, offb u64, offc u64 }
        \\message Poke { }
        \\actor A(tpu addr) {
        \\    var frame region [96]f64
        \\    var x f64 = 0.0
        \\    send tpu, Mul{grant frame, 1, 0, 8, 16}
        \\    serve {
        \\        case Poke(_):
        \\            x = frame[0]
        \\        case done(frame): quiesce
        \\    }
        \\}
    ;
    for ([_][]const u8{ bad1, bad2 }) |src| {
        var diag = joe.Diagnostic{};
        try testing.expectError(
            joe.Error.Semantics,
            joe.compile(testing.allocator, src, "A", .{}, &diag),
        );
        try testing.expect(std.mem.indexOf(u8, diag.message, "granted region") != null);
    }
}

test "A2.5: store.joe — the substrate's shape, polyfilled by an ordinary actor" {
    // §7.5's proof obligation, discharged: the Put/Get/Del contract with
    // canonical struple keys, served entirely from joe — byte equality,
    // copy, overwrite, delete, honest misses. Scorched and not.
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/store.joe");
    for ([_]bool{ false, true }) |burnt| {
        var o = try joe_run.simulate(testing.allocator, src, .{
            .loss_ppm4k = 0,
            .dup_ppm4k = 0,
            .scorch = burnt,
        });
        defer o.deinit();
        // overwrite honored, both keys retrieved, ghost + deleted both miss
        try testing.expectEqual(@as(u64, 4343), o.varOf("client", "got_hs").?);
        try testing.expectEqual(@as(u64, 111), o.varOf("client", "got_p1").?);
        try testing.expectEqual(@as(u64, 2), o.varOf("client", "misses").?);
        try testing.expectEqual(@as(u64, 8), o.varOf("client", "step").?);
        // after the Del, only ("rocci","hs") remains
        try testing.expectEqual(@as(u64, 1), o.varOf("store", "used").?);
        try testing.expectEqual(machine.CtxState.parked, o.instance("store").?.state);
    }
}

test "contended LSTN: hot delivery is a privilege of an idle core" {
    // The pricing benchmark for the v2.6 candidate. The machine-gun
    // shape that exposed the hole: a self-send looper co-resident with
    // its server. On-chip delivery (4cy) beats the loop back to LSTN,
    // so without the rule the asker's slices fuse into one unparked
    // burst, the router starves unseen (no watchdog — nothing trips),
    // and the third key dies on the cap-2 ring. With the rule, the
    // contended LSTN rotates and every key lands. Same seed, same
    // placement, one branch of difference.
    const joe_run = @import("joe_run.zig");
    const src =
        \\message Get { key bytes }
        \\message Go { }
        \\actor Asker(router addr) {
        \\    var key buf [64]u8
        \\    var step u64 = 0
        \\    send self, Go{}
        \\    serve {
        \\        case Go(_):
        \\            step += 1
        \\            if step == 1 {
        \\                pack key, ("users", 42, "profile")
        \\                send router, Get{key}
        \\                send self, Go{}
        \\            }
        \\            if step == 2 {
        \\                pack key, ("posts", 7)
        \\                send router, Get{key}
        \\                send self, Go{}
        \\            }
        \\            if step == 3 {
        \\                pack key, ("tags", 1)
        \\                send router, Get{key}
        \\                quiesce
        \\            }
        \\    }
        \\}
        \\actor Router() {
        \\    var seen u64 = 0
        \\    serve {
        \\        case Get(_):
        \\            seen += 1
        \\    }
        \\}
        \\system {
        \\    asker = Asker(router) on 0
        \\    router = Router() on 0
        \\}
    ;
    // Without the rule: the starvation, reproduced honestly.
    var bad = try joe_run.simulate(testing.allocator, src, .{
        .loss_ppm4k = 0,
        .dup_ppm4k = 0,
        .contended_lstn = false,
    });
    defer bad.deinit();
    try testing.expect(bad.stats.rejects >= 1);
    try testing.expect(bad.varOf("router", "seen").? < 3);
    // With it: every key lands, and nothing else in the corpus moved.
    var good = try joe_run.simulate(testing.allocator, src, .{
        .loss_ppm4k = 0,
        .dup_ppm4k = 0,
    });
    defer good.deinit();
    try testing.expectEqual(@as(u64, 0), good.stats.rejects);
    try testing.expectEqual(@as(u64, 3), good.varOf("router", "seen").?);
}

test "contended LSTN: the idle-core hot path keeps its privilege" {
    // crunch's self-send loop shares its core with nobody runnable, so
    // the rule must not tax it: cycle-identical with the rule on or off.
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/crunch.joe");
    var on = try joe_run.simulate(testing.allocator, src, .{});
    defer on.deinit();
    var off = try joe_run.simulate(testing.allocator, src, .{ .contended_lstn = false });
    defer off.deinit();
    try testing.expectEqual(off.cycles, on.cycles);
    try testing.expectEqual(@as(u64, 500500), on.varOf("sink", "total").?);
}

test "item 4: the joe corpus is scorch-invariant — nothing trusts the banked file" {
    // The bank-collapse verifier: registers (A, X, Y, SP, P) are
    // poisoned at every real park. If any compiled program ran on the
    // banked register file's memory, states, vars, console output or
    // even the cycle count would diverge. They must not: a context is
    // near page + run-queue entry + control block, nothing else.
    const joe_run = @import("joe_run.zig");
    const sources = [_][]const u8{
        @embedFile("programs/joe/pingpong.joe"),
        @embedFile("programs/joe/ring.joe"),
        @embedFile("programs/joe/crunch.joe"),
        @embedFile("programs/joe/supervise.joe"),
        @embedFile("programs/joe/scatter.joe"),
        @embedFile("programs/joe/pipeline.joe"),
        @embedFile("programs/joe/hello.joe"),
    };
    for (sources) |src| {
        var plain = try joe_run.simulate(testing.allocator, src, .{});
        defer plain.deinit();
        var burnt = try joe_run.simulate(testing.allocator, src, .{ .scorch = true });
        defer burnt.deinit();
        try testing.expectEqual(plain.reason, burnt.reason);
        try testing.expectEqual(plain.cycles, burnt.cycles);
        try testing.expectEqual(plain.instances.len, burnt.instances.len);
        for (plain.instances, burnt.instances) |*p, *b| {
            try testing.expectEqualStrings(p.name, b.name);
            try testing.expectEqual(p.state, b.state);
            try testing.expectEqual(p.fault, b.fault);
            for (p.vars, b.vars) |pv, bv| {
                try testing.expectEqualStrings(pv.name, bv.name);
                try testing.expectEqual(pv.value, bv.value);
            }
        }
        if (plain.console) |pc| try testing.expectEqualStrings(pc, burnt.console.?);
    }
}

test "item 4: compiled joe is stack-free — even SP owes the parks nothing" {
    // Under the collapse, SP is as volatile as A. Compiled code uses
    // static near-page temporaries instead of the stack, so there is
    // not one push in the whole corpus — init included.
    const corpus = [_]struct { src: []const u8, actors: []const []const u8 }{
        .{ .src = @embedFile("programs/joe/pingpong.joe"), .actors = &.{ "Pinger", "Ponger" } },
        .{ .src = @embedFile("programs/joe/ring.joe"), .actors = &.{ "Head", "Node" } },
        .{ .src = @embedFile("programs/joe/crunch.joe"), .actors = &.{ "Cruncher", "Sink" } },
        .{ .src = @embedFile("programs/joe/supervise.joe"), .actors = &.{ "Boss", "Griefer", "Sleeper" } },
        .{ .src = @embedFile("programs/joe/forkjoin.joe"), .actors = &.{ "Root", "Lieutenant", "Worker" } },
        .{ .src = @embedFile("programs/joe/pipeline.joe"), .actors = &.{ "Source", "Stage", "Sink" } },
        .{ .src = @embedFile("programs/joe/hello.joe"), .actors = &.{"Greeter"} },
        .{ .src = @embedFile("programs/joe/keys.joe"), .actors = &.{ "Asker", "Router" } },
        .{ .src = @embedFile("programs/joe/store.joe"), .actors = &.{ "Store", "Client" } },
        .{ .src = @embedFile("programs/joe/vecmath.joe"), .actors = &.{"Calc"} },
        .{ .src = @embedFile("programs/joe/matmul.joe"), .actors = &.{"Splat"} },
    };
    for (corpus) |entry| {
        for (entry.actors) |name| {
            var r = try joe.compile(testing.allocator, entry.src, name, .{}, null);
            defer r.deinit();
            for ([_][]const u8{ "PHA", "PLA", "PHX", "PLX", "PHY", "PLY", "PHP", "PLP", "TXS", "TSX" }) |op| {
                try testing.expect(std.mem.indexOf(u8, r.asm_text, op) == null);
            }
        }
    }
}

test "joe: supervision — spawn, respawn, hung, abandoned, all from the system block" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/supervise.joe");
    var o = try joe_run.simulate(testing.allocator, src, .{});
    defer o.deinit();
    // The Boss observed exactly the policy it declared: the Griefer
    // crashed on each of its 3 lives (2 respawns + the abandonment),
    // the Sleeper's dishonest `bounded` hung once and was respawned,
    // then abandoned. Budgets ran out; the Boss halted cleanly.
    const boss = o.instance("boss").?;
    try testing.expectEqual(machine.CtxState.halted, boss.state);
    try testing.expectEqual(@as(u64, 2), o.varOf("boss", "crashes").?);
    try testing.expectEqual(@as(u64, 1), o.varOf("boss", "hangs").?);
    try testing.expectEqual(@as(u64, 2), o.varOf("boss", "lost").?);
    // The dead lie where they fell, each with its honest fault code —
    // and their timers were disarmed, or the machine would never have
    // gone quiet (this test would hang at max_cycles).
    const griefer = o.instance("boss/Griefer#0").?;
    try testing.expectEqual(machine.CtxState.faulted, griefer.state);
    try testing.expectEqual(machine.Fault.brk, griefer.fault);
    const sleeper = o.instance("boss/Sleeper#1").?;
    try testing.expectEqual(machine.CtxState.faulted, sleeper.state);
    try testing.expectEqual(machine.Fault.watchdog, sleeper.fault);
}

test "joe A1.1: crunch — unbounded work is a self-send loop, one park per slice" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/crunch.joe");
    var o = try joe_run.simulate(testing.allocator, src, .{});
    defer o.deinit();
    // Sum 1..1000 in slices of 50: twenty parks, one exact total.
    try testing.expectEqual(machine.CtxState.halted, o.instance("cr").?.state);
    try testing.expectEqual(@as(u64, 500500), o.varOf("cr", "acc").?);
    try testing.expectEqual(@as(u64, 500500), o.varOf("sink", "total").?);
    // Under the default 25%-loss fabric, nothing was lost: a message to
    // yourself is on-chip — same core never rides the mesh — so the
    // self-send loop needs no retry discipline. That is why A1.1 can
    // replace `while` with it.
    try testing.expectEqual(@as(u64, 0), o.stats.lost);
    try testing.expectEqual(o.stats.sends, o.stats.delivered);
}

test "joe: scatter — the result is the ack; re-asks converge through loss" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/scatter.joe");
    var o = try joe_run.simulate(testing.allocator, src, .{});
    defer o.deinit();
    try testing.expectEqual(machine.CtxState.halted, o.instance("coord").?.state);
    try testing.expectEqual(@as(u64, 15), o.varOf("coord", "got").?);
    // Reply is a 16-byte message: this is the SEND path's gauntlet.
    try testing.expectEqual(@as(u64, 500), o.varOf("coord", "r0").?);
    try testing.expectEqual(@as(u64, 501), o.varOf("coord", "r1").?);
    try testing.expectEqual(@as(u64, 502), o.varOf("coord", "r2").?);
    try testing.expectEqual(@as(u64, 503), o.varOf("coord", "r3").?);
}

test "joe: pipeline — backpressure by silence, termination as a phase" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/pipeline.joe");
    // 25% loss AND deep loss: every item arrives checksum-verified, the
    // pill drains the line, and every stage lame-ducks into quiescence.
    for ([_]u16{ 1024, 2500 }) |loss| {
        var o = try joe_run.simulate(testing.allocator, src, .{ .loss_ppm4k = loss });
        defer o.deinit();
        try testing.expectEqual(machine.CtxState.halted, o.instance("source").?.state);
        try testing.expectEqual(machine.CtxState.parked, o.instance("s1").?.state);
        try testing.expectEqual(machine.CtxState.parked, o.instance("s2").?.state);
        // sum = Σ(k+100) for k=0..5, +1000 per stage per item, ×2 stages
        try testing.expectEqual(@as(u64, 12615), o.varOf("sink", "sum").?);
        try testing.expectEqual(@as(u64, 7), o.varOf("sink", "expect").?);
    }
}

test "joe: hello — the console is just another name in the system block" {
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/joe/hello.joe");
    var o = try joe_run.simulate(testing.allocator, src, .{
        .loss_ppm4k = 0,
        .dup_ppm4k = 0,
    });
    defer o.deinit();
    try testing.expectEqual(machine.CtxState.halted, o.instance("greeter").?.state);
    try testing.expectEqualStrings("HELLO, WORLD - JOE SPEAKS.\n", o.console.?);
}

test "joe: fork-join — replication, groups, for; the tree is the reliability" {
    const joe_run = @import("joe_run.zig");
    // The shipped forkjoin.joe runs 8x125 (sim6564 joe src/programs/
    // joe/forkjoin.joe); the suite runs the same shape at 2x20 so Debug
    // stays quick. Every hop acks through the tree — workers retry
    // Results until acked, lieutenants retry Done, the root lame-ducks
    // instead of halting so no straggler is ever stranded.
    const src =
        \\message Task { v u32, j u32 }
        \\message Result { k u32, v u64 }
        \\message Ok { k u32 }
        \\message Done { k u32, v u64 }
        \\message OkD { k u32 }
        \\actor Root(ls []addr, task u32, quota u32) {
        \\    var got [16]u64
        \\    var n u64 = 0
        \\    var sum u64 = 0
        \\    for (k, l) in ls { send l, Task{task, k} }
        \\    serve {
        \\        case Done(d):
        \\            send ls[d.k], OkD{d.k}
        \\            if got[d.k] == 0 {
        \\                got[d.k] = 1
        \\                n += 1
        \\                sum += d.v
        \\                if n == quota { quiesce }
        \\            }
        \\        after 700:
        \\            for (k, l) in ls { if got[k] == 0 { send l, Task{task, k} } }
        \\    }
        \\    quiesce {
        \\        case Done(d): send ls[d.k], OkD{d.k}
        \\    }
        \\}
        \\actor Lieutenant(ws []addr, root addr, quota u32) {
        \\    var got [32]u64
        \\    var n u64 = 0
        \\    var sum u64 = 0
        \\    var fired u64 = 0
        \\    var myk u64 = 0
        \\    var task u64 = 0
        \\    serve {
        \\        case Task(t) where fired == 0:
        \\            fired = 1
        \\            myk = t.j
        \\            task = t.v
        \\            for (j, w) in ws { send w, Task{t.v, j} }
        \\        case Task(_):
        \\            for (j, w) in ws { if got[j] == 0 { send w, Task{task, j} } }
        \\        case Result(r):
        \\            send ws[r.k], Ok{r.k}
        \\            if got[r.k] == 0 {
        \\                got[r.k] = 1
        \\                n += 1
        \\                sum += r.v
        \\                if n == quota { send root, Done{myk, sum} }
        \\            }
        \\        case OkD(_):
        \\            quiesce
        \\        after 700:
        \\            if n == quota { send root, Done{myk, sum} }
        \\    }
        \\    quiesce {
        \\        case Result(r): send ws[r.k], Ok{r.k}
        \\    }
        \\}
        \\actor Worker(lt addr) {
        \\    var j u64 = 0
        \\    var val u64 = 0
        \\    var need u64 = 0
        \\    serve {
        \\        case Task(t):
        \\            j = t.j
        \\            val = t.v + 1
        \\            need = 1
        \\            send lt, Result{t.j, val}
        \\        case Ok(o) where o.k == j:
        \\            quiesce
        \\        case Ok(_):
        \\        after 700:
        \\            if need == 1 { send lt, Result{j, val} }
        \\    }
        \\}
        \\system {
        \\    root = Root(ls, 500, 2) on 0
        \\    ls = Lieutenant[2](ws, root, 20)
        \\    ws = Worker[40](ls)
        \\}
    ;
    for ([_]u16{ 0, 1024 }) |loss| {
        var o = try joe_run.simulate(testing.allocator, src, .{
            .loss_ppm4k = loss,
            .dup_ppm4k = if (loss == 0) 0 else 128,
        });
        defer o.deinit();
        try testing.expectEqual(@as(u64, 2), o.varOf("root", "n").?);
        try testing.expectEqual(@as(u64, 40 * 501), o.varOf("root", "sum").?);
        try testing.expectEqual(machine.CtxState.parked, o.instance("root").?.state);
        try testing.expectEqual(@as(u64, 20 * 501), o.varOf("ls[0]", "sum").?);
        try testing.expectEqual(@as(u64, 20 * 501), o.varOf("ls[1]", "sum").?);
        // Total quiescence: every worker got its ack and stopped its
        // clock, or the machine would have run to max_cycles.
        for (o.instances) |inst| {
            try testing.expect(inst.state == .parked);
        }
    }
}

const mandel_cols = 64;
const mandel_rows = 22;

/// The independent host-f64 computation one mandel row must match.
fn mandelOracleRow(alloc: std.mem.Allocator, row: usize) ![]u8 {
    const pal = " .,:;~=+xoXO#%$&@";
    const dx: f64 = 2.5 / 63.0;
    const dy: f64 = 2.2 / 21.0;
    var line = try alloc.alloc(u8, mandel_cols + 1);
    var cy: f64 = 1.1;
    for (0..row) |_| cy = cy - dy;
    var cx: f64 = -2.0;
    for (0..mandel_cols) |c| {
        var zx: f64 = 0.0;
        var zy: f64 = 0.0;
        var n: usize = 0;
        while (true) {
            const zx2 = zx * zx;
            const zy2 = zy * zy;
            if (!(zy2 + zx2 < 4.0)) break;
            const t = zx * zy;
            zy = (t + t) + cy;
            zx = (zx2 - zy2) + cx;
            n += 1;
            if (n == 16) break;
        }
        line[c] = pal[n];
        cx = cx + dx;
    }
    line[mandel_cols] = '\n';
    return line;
}

test "mandel.joe: the language draws the same picture as the assembly and the host" {
    // The third implementation. Amendment 3's surface (const/let/append/
    // raw send) plus Tier 0 FP, against the same oracle — one misrounded
    // FP op anywhere in the tower is a visibly wrong character.
    var o = try @import("joe_run.zig").simulate(testing.allocator, @embedFile("programs/joe/mandel.joe"), .{
        .loss_ppm4k = 0,
        .dup_ppm4k = 0,
    });
    defer o.deinit();
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    const text = o.console.?;
    try testing.expectEqual(@as(usize, (mandel_cols + 1) * mandel_rows), text.len);
    for (0..mandel_rows) |r| {
        const expected = try mandelOracleRow(testing.allocator, r);
        defer testing.allocator.free(expected);
        const got = text[r * (mandel_cols + 1) ..][0 .. mandel_cols + 1];
        try testing.expectEqualStrings(expected, got);
    }
}

test "mandel: the whole picture matches the host-f64 oracle, row for row" {
    // 1,408 points, up to 16 iterations each — thousands of FMUL/FADD/
    // FSUB/FCMP results, every one of which must round exactly as the
    // host's IEEE doubles do, or a character somewhere is wrong.
    var o = try asm_run.simulate(testing.allocator, &asm_src.mandel, clean_fabric);
    defer o.deinit();
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    const text = o.console.?;
    try testing.expectEqual(@as(usize, (mandel_cols + 1) * mandel_rows), text.len);
    for (0..mandel_rows) |r| {
        const expected = try mandelOracleRow(testing.allocator, r);
        defer testing.allocator.free(expected);
        const got = text[r * (mandel_cols + 1) ..][0 .. mandel_cols + 1];
        try testing.expectEqualStrings(expected, got);
    }
}

test "the extended page does not stack: $42 $42 faults, and so does an undefined slot" {
    for ([_]u8{ 0x42, 0x00 }) |second| {
        var m = try Machine.init(testing.allocator, .{
            .cores = 1,
            .contexts_per_core = 1,
            .ram_size = 0x4000,
        });
        defer m.deinit();
        m.load(0, 0x1000, &.{ 0x42, second });
        try m.spawn(0, 0, 0x1000, 0x3000, 0);
        try testing.expectEqual(machine.StopReason.faulted, try m.run());
        try testing.expectEqual(machine.Fault.bad_opcode, m.cores[0].contexts[0].fault);
    }
}

test "WDEX with no watchdog armed is a no-op: nothing to extend, nothing to fault" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    // No watchdog, no ceiling: a joe program full of `bounded` blocks must
    // run identically whether or not anyone is holding its leash.
    try assembleInto(&m, 0,
        \\        .org $1000
        \\        WDEX ##123456
        \\        LDX #200
        \\sp:     DEX
        \\        BNE sp
        \\        HLT
    );
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    try testing.expectEqual(machine.CtxState.halted, m.cores[0].contexts[0].state);
}

test "SPWN invalidates the dead incarnation's queued continuations" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x4000,
    });
    defer m.deinit();

    // Child queues a continuation, then crashes. The supervisor restarts it
    // at `alive`. The stale continuation (`dead`, from generation 0) must
    // never run.
    const child_src =
        \\        .org $1000
        \\        CONT dead
        \\        BRK
        \\alive:  LDA #2
        \\        STA $808
        \\        HLT
        \\dead:   LDA #$FF
        \\        STA $810
        \\        HLT
    ;
    const sup_src =
        \\        .org $1100
        \\wait1:  LSTN 1
        \\        CQPOP 1
        \\        BEQ wait1
        \\        SPWN $900       ; restart the child at `alive`
        \\wait2:  LSTN 1          ; then wait for its clean exit
        \\        CQPOP 1
        \\        BEQ wait2
        \\        HLT
    ;
    var child_out = try asm6564.assemble(testing.allocator, child_src, null);
    defer child_out.deinit();
    var sup_out = try asm6564.assemble(testing.allocator, sup_src, null);
    defer sup_out.deinit();
    m.load(0, child_out.origin, child_out.code);
    m.load(0, sup_out.origin, sup_out.code);

    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 3,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    var blk: [32]u8 = undefined;
    std.mem.writeInt(u64, blk[0..8], 1, .little); // target ctx 1
    std.mem.writeInt(u64, blk[8..16], child_out.symbol("alive").?, .little);
    std.mem.writeInt(u64, blk[16..24], 0x3800, .little);
    std.mem.writeInt(u64, blk[24..32], 0, .little);
    m.writeNear(0, 0, 0x900, &blk);
    m.linkSupervisor(0, 1, 0, ring.slot_cq);

    try m.spawn(0, 1, 0x1000, 0x3000, 0);
    try m.spawn(0, 0, 0x1100, 0x2800, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());

    const child = &m.cores[0].contexts[1];
    try testing.expectEqual(machine.CtxState.halted, child.state);
    try testing.expectEqual(@as(u32, 1), child.gen);
    // The new incarnation ran…
    try testing.expectEqual(
        @as(u64, 2),
        std.mem.readInt(u64, child.near[0x808..][0..8], .little),
    );
    // …and the dead one's continuation never did.
    try testing.expectEqual(
        @as(u64, 0),
        std.mem.readInt(u64, child.near[0x810..][0..8], .little),
    );
}

test "SPWN of self or a nonexistent context faults the spawner" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    const src =
        \\        .org $1000
        \\        SPWN $900
        \\        HLT
    ;
    var out = try asm6564.assemble(testing.allocator, src, null);
    defer out.deinit();
    m.load(0, out.origin, out.code);
    var blk: [32]u8 = undefined;
    std.mem.writeInt(u64, blk[0..8], 0, .little); // ctx 0 = the spawner itself
    @memset(blk[8..], 0);
    m.writeNear(0, 0, 0x900, &blk);
    try m.spawn(0, 0, 0x1000, 0x2000, 0);
    try testing.expectEqual(machine.StopReason.faulted, try m.run());
    try testing.expectEqual(machine.Fault.bad_descriptor, m.cores[0].contexts[0].fault);
}

// ── Phase 3: pipeline dataflow ───────────────────────────────────────────

test "pipeline: every item transformed, delivered, verified across a lossy fabric" {
    const sys = try asm_run.pipelineSystem(testing.allocator, 12, 2);
    defer testing.allocator.free(sys);
    var o = try asm_run.simulateSystem(testing.allocator, &asm_src.pipeline, sys, .{ .loss_ppm4k = 1024 });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 13), o.varOf("sink", "consumed").?); // 12 items + DONE
    try testing.expectEqual(@as(u64, 0), o.varOf("sink", "verify_errors").?);
    // Σ ((s+1)·2^n − 1): 2 stages of double-and-decrement over 12 items.
    try testing.expectEqual(@as(u64, 4 * (12 * 13 / 2) - 12), o.varOf("sink", "checksum").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("source").?.state);
    // Both stages reached lame duck — the poison pill made it through.
    try testing.expectEqual(@as(u64, 2), o.varOf("s1", "phase").?);
    try testing.expectEqual(@as(u64, 2), o.varOf("s2", "phase").?);
    // Quiesced, not timed out: the lame-duck shutdown converged.
    try testing.expectEqual(machine.StopReason.deadlock, o.reason);
    try testing.expect(o.stats.lost > 0); // the fabric really was hostile
}

test "pipeline: zero stages (source direct to sink)" {
    const sys = try asm_run.pipelineSystem(testing.allocator, 8, 0);
    defer testing.allocator.free(sys);
    var o = try asm_run.simulateSystem(testing.allocator, &asm_src.pipeline, sys, .{
        .seed = 7,
        .loss_ppm4k = 512,
    });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 9), o.varOf("sink", "consumed").?);
    try testing.expectEqual(@as(u64, 0), o.varOf("sink", "verify_errors").?);
    try testing.expectEqual(@as(u64, (8 * 9 / 2) - 8), o.varOf("sink", "checksum").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("source").?.state);
    try testing.expectEqual(machine.StopReason.deadlock, o.reason);
}

// ── Phase 3: scatter-gather ──────────────────────────────────────────────
// The converted contract bakes the demo's full 8-worker shape (the staged
// fan-out chain is part of the program's contract now); Σ(i+3)² for
// i=1..8 is 492.

test "scatter-gather: all results gathered and verified over a lossy fabric" {
    var o = try asm_run.simulate(testing.allocator, &asm_src.scatter, .{ .loss_ppm4k = 1024 });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 8), o.varOf("c", "gathered").?);
    try testing.expectEqual(@as(u64, 492), o.varOf("c", "sum").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("c").?.state);
    try testing.expectEqual(machine.StopReason.deadlock, o.reason); // quiesced
    // The fabric was hostile and the retry loop actually worked for a living.
    try testing.expect(o.stats.lost > 0);
    try testing.expect(o.varOf("c", "scatter_sends").? >= 8);
}

test "scatter-gather: full fan-out saturates the cap-8 fan-in ring" {
    var o = try asm_run.simulate(testing.allocator, &asm_src.scatter, .{
        .seed = 1,
        .loss_ppm4k = 0,
        .dup_ppm4k = 0,
    });
    defer o.deinit();
    try testing.expectEqual(@as(u64, 8), o.varOf("c", "gathered").?);
    try testing.expectEqual(@as(u64, 492), o.varOf("c", "sum").?);
    try testing.expectEqual(machine.CtxState.halted, o.instance("c").?.state);
}

// ── Armstrong's ring (Programming Erlang, ch. 12) ────────────────────────

test "armstrong ring: N x M passes, message comes home to node 0" {
    const sys = try ringSystem(testing.allocator, 8, 4);
    defer testing.allocator.free(sys);
    var o = try asm_run.simulateSystem(testing.allocator, &asm_src.ring, sys, .{});
    defer o.deinit();
    const fin = ringFinishers(&o);
    try testing.expectEqual(@as(usize, 1), fin.count);
    try testing.expect(fin.node0);
    try testing.expectEqual(machine.StopReason.deadlock, o.reason); // quiesced
}

test "armstrong ring: steady-state cost per pass stays two-digit" {
    const sys = try ringSystem(testing.allocator, 64, 20);
    defer testing.allocator.free(sys);
    var o = try asm_run.simulateSystem(testing.allocator, &asm_src.ring, sys, .{});
    defer o.deinit();
    const fin = ringFinishers(&o);
    try testing.expect(fin.count == 1 and fin.node0);
    // The §2.2 claim, as a regression guard: actor-to-actor messaging on one
    // core, scheduler included, stays under 100 cycles per pass.
    try testing.expect(o.cycles / (64 * 20) < 100);
}

// ── MAC: one-byte vectored calls (pre-normative; MAC & chains sketch) ────

test "MAC calls through the per-context vector table" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    // MAC 0 → square A into $860; MAC 15 → increment $868. Vectors staged by
    // the program itself: near-page stores into MACTAB ($F80).
    const src =
        \\        .org $1000
        \\        LDA ##double
        \\        STA $F80            ; MACTAB slot 0
        \\        LDA ##bump
        \\        STA $FF8            ; MACTAB slot 15
        \\        LDA #21
        \\        MAC 0
        \\        MAC 15
        \\        MAC 15
        \\        HLT
        \\double: ASL
        \\        STA $860
        \\        RTS
        \\bump:   INC $868
        \\        RTS
    ;
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    const ctx = &m.cores[0].contexts[0];
    try testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, ctx.near[0x860..][0..8], .little));
    try testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, ctx.near[0x868..][0..8], .little));
    try testing.expectEqual(@as(u64, 3), m.stats.macro_calls);
}

test "MAC through a null vector faults with bad_macro" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    try assembleInto(&m, 0, ".org $1000\n MAC 7\n HLT\n");
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.faulted, try m.run());
    try testing.expectEqual(machine.Fault.bad_macro, m.cores[0].contexts[0].fault);
}

test "MAC vectors survive SPWN: a restarted actor keeps its bindings" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x4000,
    });
    defer m.deinit();
    // Child binds MAC 0 in its first life, crashes; second life calls MAC 0
    // without rebinding — the near page (and so MACTAB) survived.
    const child_src =
        \\        .org $1000
        \\        LDA ##mark
        \\        STA $F80
        \\        BRK
        \\life2:  MAC 0
        \\        HLT
        \\mark:   INC $870
        \\        RTS
    ;
    const sup_src =
        \\        .org $1200
        \\wait1:  LSTN 1
        \\        CQPOP 1
        \\        BEQ wait1
        \\        SPWN $900
        \\wait2:  LSTN 1
        \\        CQPOP 1
        \\        BEQ wait2
        \\        HLT
    ;
    var child_out = try asm6564.assemble(testing.allocator, child_src, null);
    defer child_out.deinit();
    var sup_out = try asm6564.assemble(testing.allocator, sup_src, null);
    defer sup_out.deinit();
    m.load(0, child_out.origin, child_out.code);
    m.load(0, sup_out.origin, sup_out.code);
    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 3,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    var blk: [32]u8 = undefined;
    std.mem.writeInt(u64, blk[0..8], 1, .little);
    std.mem.writeInt(u64, blk[8..16], child_out.symbol("life2").?, .little);
    std.mem.writeInt(u64, blk[16..24], 0x3800, .little);
    std.mem.writeInt(u64, blk[24..32], 0, .little);
    m.writeNear(0, 0, 0x900, &blk);
    m.linkSupervisor(0, 1, 0, ring.slot_cq);
    try m.spawn(0, 1, 0x1000, 0x3000, 0);
    try m.spawn(0, 0, 0x1200, 0x2800, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    try testing.expectEqual(
        @as(u64, 1),
        std.mem.readInt(u64, m.cores[0].contexts[1].near[0x870..][0..8], .little),
    );
}

test "AUTO_REPOST on a capacity-1 ring faults: zero-width validity window" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 2,
        .ram_size = 0x8000,
    });
    defer m.deinit();
    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(0, 1, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0,
    });
    wireSender(&m, 0, 0, 0x2300, 0x2400);
    wireReceiver(&m, 0, 1, 0x2000, 0x2100, 0);
    // Force the receiver's cap-1 RX ring into AUTO_REPOST — architecturally
    // meaningless, must fault at the CQPOP that would trigger it.
    var d = ring.Desc{
        .base = 0x2100,
        .cap_log2 = 0,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .flags = ring.desc_flag_auto_repost,
        .head = 0,
        .tail = 0,
        .token = 0,
    };
    m.setRing(0, 1, ring.slot_rx, d);
    _ = &d;

    const sender_src =
        \\        .org $1000
        \\        LDA ##$FF00_0000_0000_0000
        \\        STA $800
        \\        LDA #9
        \\        TXR ($800),A
        \\        HLT
    ;
    try assembleInto(&m, 0, sender_src);
    try assembleInto(&m, 0, receiver_src);
    try m.spawn(0, 1, 0x1400, 0x3800, 0);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.faulted, try m.run());
    try testing.expectEqual(machine.Fault.bad_descriptor, m.cores[0].contexts[1].fault);
}

test "armstrong ring at full scale: 200 nodes, layout stripes stay disjoint" {
    const sys = try ringSystem(testing.allocator, 200, 10);
    defer testing.allocator.free(sys);
    var o = try asm_run.simulateSystem(testing.allocator, &asm_src.ring, sys, .{});
    defer o.deinit();
    const fin = ringFinishers(&o);
    try testing.expect(fin.count == 1 and fin.node0);
    try testing.expect(o.cycles / 2000 < 100);
}

// ── LINK chains and AUTO_REARM (sketch §3.1, §3.2) ───────────────────────

// A sender that collects exactly three send-tagged completion records,
// storing each status byte at $868+8k, then halts. Shared by the chain
// tests: "stage N, collect N records" is the property under test.
const chain_sender_src =
    \\        .org $1000
    \\        SEND 0              ; fire the chain head
    \\loop:   LSTN 1
    \\        CQPOP 1
    \\        BEQ loop
    \\        TAY
    \\        AND #$FF
    \\        CMP #2
    \\        BNE loop            ; only send records count
    \\        TYA
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        AND #$FF
    \\        STA $8F8            ; status, parked
    \\        LDA $860
    \\        ASL
    \\        ASL
    \\        ASL
    \\        TAX
    \\        LDA $8F8
    \\        STA $868,X          ; statuses land at $868, $870, $878
    \\        INC $860
    \\        LDA $860
    \\        CMP #3
    \\        BNE loop
    \\        HLT
;

// An immortal receiver on an AUTO_REPOST ring: counts deliveries in $860,
// sums the delivered words in $868.
const chain_receiver_src =
    \\        .org $1000
    \\serve:  LSTN 1
    \\        CQPOP 1
    \\        BEQ serve
    \\        TAY
    \\        AND #$FF
    \\        CMP #3
    \\        BNE serve
    \\        TYA
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        AND #$FF
    \\        CMP #0
    \\        BNE serve
    \\        STX $8E0
    \\        INC $860            ; count it
    \\        CLC
    \\        LDA ($8E0)
    \\        ADC $868
    \\        STA $868            ; sum it
    \\        BRA serve
;

fn wireChainPair(m: *Machine) !void {
    // Sender core 0: SQ 0 (head at $2400), CQ 1. Receiver core 1: CQ 1 and
    // a cap-2 AUTO_REPOST RX with cookie-addressed cells.
    wireSender(m, 0, 0, 0x2300, 0x2400);
    m.setRing(1, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 3,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(1, 0, ring.slot_rx, .{
        .base = 0x2A00,
        .cap_log2 = 1,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .flags = ring.desc_flag_auto_repost,
        .head = 0,
        .tail = 2, // both landing buffers granted by the loader
        .token = 0,
    });
    var slot_i: u64 = 0;
    while (slot_i < 2) : (slot_i += 1) {
        const cell: u64 = 0x2200 + 8 * slot_i;
        const entry = ring.RxEntry{ .buf = cell, .cap = 8, .filled = 0, .cookie = cell };
        var eb: [32]u8 = undefined;
        for (entry.pack(), 0..) |word, wi|
            std.mem.writeInt(u64, eb[wi * 8 ..][0..8], word, .little);
        m.load(1, 0x2A00 + 32 * slot_i, &eb);
    }
}

fn stageChainEntry(m: *Machine, addr: u64, sqe: ring.SqEntry) void {
    var eb: [32]u8 = undefined;
    for (sqe.pack(), 0..) |word, wi|
        std.mem.writeInt(u64, eb[wi * 8 ..][0..8], word, .little);
    if (addr < machine.near_size) {
        m.writeNear(0, 0, @intCast(addr), &eb);
    } else {
        m.load(0, addr, &eb);
    }
}

test "LINK: a three-entry chain fires in order from one doorbell" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 2,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
    });
    defer m.deinit();
    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(1, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0,
    });
    try wireChainPair(&m);
    // Payload words 1, 2, 3 at distinct buffers.
    var wbuf: [8]u8 = undefined;
    for ([_]u64{ 1, 2, 3 }, 0..) |v, i| {
        std.mem.writeInt(u64, &wbuf, v, .little);
        m.load(0, 0x2500 + 16 * @as(u64, i), &wbuf);
    }
    stageChainEntry(&m, 0x2400, .{ // head, in the SQ ring
        .op = .send,
        .flags = ring.SqEntry.flag_link,
        .link = 0xC00,
        .target = ring.windowAddr(0, 0),
        .buf = 0x2500,
        .len = 8,
        .cookie_lo = 1,
    });
    stageChainEntry(&m, 0xC00, .{
        .op = .send,
        .flags = ring.SqEntry.flag_link,
        .link = 0xC20,
        .target = ring.windowAddr(0, 0),
        .buf = 0x2510,
        .len = 8,
        .cookie_lo = 2,
    });
    stageChainEntry(&m, 0xC20, .{
        .op = .send,
        .target = ring.windowAddr(0, 0),
        .buf = 0x2520,
        .len = 8,
        .cookie_lo = 3,
    });
    try assembleInto(&m, 0, chain_sender_src);
    try assembleInto(&m, 1, chain_receiver_src);
    try m.spawn(1, 0, 0x1000, 0x3000, 0);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    _ = try m.run();

    try testing.expectEqual(@as(u64, 2), m.stats.chain_fires);
    try testing.expectEqual(@as(u64, 0), m.stats.chain_cancels);
    const rn = &m.cores[1].contexts[0].near;
    try testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, rn[0x860..][0..8], .little));
    try testing.expectEqual(@as(u64, 6), std.mem.readInt(u64, rn[0x868..][0..8], .little));
    // Sender collected three ok records.
    const sn = &m.cores[0].contexts[0].near;
    for (0..3) |k| {
        try testing.expectEqual(
            @as(u64, @intFromEnum(ring.Status.ok)),
            std.mem.readInt(u64, sn[0x868 + 8 * k ..][0..8], .little),
        );
    }
}

test "LINK: a broken chain cancels loudly — stage N, collect N records" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 2,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
    });
    defer m.deinit();
    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(1, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0,
    });
    // PTT 1 stays empty: entry 2 sends through it and rejects at the RBC.
    try wireChainPair(&m);
    var wbuf: [8]u8 = undefined;
    std.mem.writeInt(u64, &wbuf, 9, .little);
    m.load(0, 0x2500, &wbuf);
    stageChainEntry(&m, 0x2400, .{
        .op = .send,
        .flags = ring.SqEntry.flag_link,
        .link = 0xC00,
        .target = ring.windowAddr(0, 0),
        .buf = 0x2500,
        .len = 8,
        .cookie_lo = 1,
    });
    stageChainEntry(&m, 0xC00, .{ // the doomed entry: no capability
        .op = .send,
        .flags = ring.SqEntry.flag_link,
        .link = 0xC20,
        .target = ring.windowAddr(1, 0),
        .buf = 0x2500,
        .len = 8,
        .cookie_lo = 2,
    });
    stageChainEntry(&m, 0xC20, .{ // never submitted: cancelled
        .op = .send,
        .target = ring.windowAddr(0, 0),
        .buf = 0x2500,
        .len = 8,
        .cookie_lo = 3,
    });
    try assembleInto(&m, 0, chain_sender_src);
    try assembleInto(&m, 1, chain_receiver_src);
    try m.spawn(1, 0, 0x1000, 0x3000, 0);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    _ = try m.run();

    try testing.expectEqual(@as(u64, 1), m.stats.chain_fires);
    try testing.expectEqual(@as(u64, 1), m.stats.chain_cancels);
    // Only the head's payload arrived.
    const rn = &m.cores[1].contexts[0].near;
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, rn[0x860..][0..8], .little));
    // Sender saw exactly: ok, reject_capability, chain_cancelled.
    const sn = &m.cores[0].contexts[0].near;
    const expected = [_]ring.Status{ .ok, .reject_capability, .chain_cancelled };
    for (expected, 0..) |st, k| {
        try testing.expectEqual(
            @as(u64, @intFromEnum(st)),
            std.mem.readInt(u64, sn[0x868 + 8 * k ..][0..8], .little),
        );
    }
}

test "AUTO_REARM: stage once, tick forever, disarm by clearing the flag" {
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
    });
    defer m.deinit();
    // PTT 0: unroutable — the black-hole timer target.
    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0,
    });
    wireSender(&m, 0, 0, 0x2300, 0x2400);
    stageChainEntry(&m, 0x2400, .{
        .op = .txr,
        .flags = ring.SqEntry.flag_auto_rearm,
        .target = ring.windowAddr(0, 0),
        .buf = 0,
        .len = 0,
        .cookie_lo = 0x77,
    });
    const src =
        \\        .org $1000
        \\        LDA #3
        \\        STA $860            ; ticks to observe
        \\        SEND 0              ; arm: one doorbell, then never again
        \\loop:   LSTN 1
        \\        CQPOP 1
        \\        BEQ loop
        \\        AND #$FF
        \\        CMP #1              ; tag txr: a tick
        \\        BNE loop
        \\        DEC $860
        \\        BNE loop
        \\        LDA #2
        \\        STA !$2400          ; disarm: clear AUTO_REARM in the entry
        \\        HLT
    ;
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    // Three ticks observed = two rearms at least (the disarm race allows
    // one more in-flight tick after the flag clears; it must NOT rearm).
    try testing.expect(m.stats.auto_rearms >= 2);
    try testing.expect(m.stats.auto_rearms <= 3);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(
        u64,
        m.cores[0].contexts[0].near[0x860..][0..8],
        .little,
    ));
}

// ── Capstone stress tests ────────────────────────────────────────────────

test "big brother: 600 senders saturate the ring; deferred repost keeps sums exact" {
    // 600 > 256 landing buffers → the ring drains dry and rejects fly. The
    // original pop-time-immediate AUTO_REPOST grant corrupted checksums in
    // exactly this regime (payload overwritten between pop and read); the
    // deferred grant must keep every value intact.
    const sys = try floodSystem(testing.allocator, 600);
    defer testing.allocator.free(sys);
    var o = try asm_run.simulateSystem(testing.allocator, &asm_src.bigbrother, sys, clean_fabric);
    defer o.deinit();
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqual(@as(u64, 600), o.varOf("sink", "count").?);
    try testing.expectEqual(@as(u64, 600 * 601 / 2), o.varOf("sink", "checksum").?);
    try testing.expect(o.stats.rejects > 0); // saturation really happened
    try testing.expectEqual(@as(u64, 0), o.stats.cq_overflows);
}

test "big brother: sub-saturation flood delivers first time" {
    const sys = try floodSystem(testing.allocator, 200);
    defer testing.allocator.free(sys);
    var o = try asm_run.simulateSystem(testing.allocator, &asm_src.bigbrother, sys, clean_fabric);
    defer o.deinit();
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqual(@as(u64, 200), o.varOf("sink", "count").?);
    try testing.expectEqual(@as(u64, 200 * 201 / 2), o.varOf("sink", "checksum").?);
}

test "fork-join matrix at full scale: 8x125, forked, relayed, joined" {
    var o = try asm_run.simulate(testing.allocator, &asm_src.forkjoin, clean_fabric);
    defer o.deinit();
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqual(@as(u64, 1000), o.varOf("agg", "count").?);
    // Σ (g+1) for g = 1..1000: every worker's number, relayed once.
    try testing.expectEqual(@as(u64, 501500), o.varOf("agg", "checksum").?);
    try testing.expectEqual(@as(u64, 7), o.stats.chain_fires);
    try testing.expectEqual(@as(u64, 0), o.stats.cq_overflows);
}

// ── The peripheral row (§7) ──────────────────────────────────────────────

test "hello: the console device hears the machine's first words" {
    var o = try asm_run.simulate(testing.allocator, &asm_src.hello, clean_fabric);
    defer o.deinit();
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqualStrings("HELLO, WORLD - THE 6564 SPEAKS.\n", o.console.?);
    try testing.expectEqual(@as(u64, 1), o.stats.dev_deliveries);
    try testing.expectEqual(@as(u64, 0), o.stats.dev_replies);
}

test "periph.joe: the device conversation, in the language (A3.3)" {
    // Every answer here arrives as an ordinary `case`, because every ask
    // carried a tag the device echoed. Same entropy stream as the
    // assembly errand — the language changed, the machine did not.
    var o = try @import("joe_run.zig").simulate(testing.allocator, @embedFile("programs/joe/periph.joe"), .{
        .loss_ppm4k = 0,
        .dup_ppm4k = 0,
    });
    defer o.deinit();
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    const text = o.console.?;
    try testing.expect(std.mem.startsWith(u8, text, "6564 PERIPHERAL BUS CHECK\n"));
    try testing.expect(std.mem.indexOf(u8, text, "ENTROPY 33FB3C626C1F610A\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "BLOCK OK\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "CYCLES ") != null);
    // The write's echoed ack is a real sequencing point: without it the
    // read races the write and the sector comes back empty.
    try testing.expectEqual(@as(u64, 3), o.varOf("p", "step").?);
    const elapsed = o.varOf("p", "elapsed").?;
    try testing.expect(elapsed > 0 and elapsed < o.cycles);
    try testing.expectEqual(@as(u64, 0), o.stats.lost);
}

test "peripheral row: console, entropy, rtc and block all answer" {
    var o = try asm_run.simulate(testing.allocator, &asm_src.periph, clean_fabric);
    defer o.deinit();
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    const text = o.console.?;
    try testing.expect(std.mem.indexOf(u8, text, "BLOCK OK") != null);
    try testing.expect(std.mem.startsWith(u8, text, "6564 PERIPHERAL BUS CHECK\n"));
    try testing.expect(std.mem.indexOf(u8, text, "ENTROPY ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "CYCLES ") != null);
    // The program's RTC arithmetic must agree with the fabric's clock:
    // elapsed is bounded by the whole run.
    const elapsed = o.varOf("p", "elapsed").?;
    try testing.expect(elapsed > 0 and elapsed < o.cycles);
    try testing.expectEqual(@as(u64, 4), o.stats.dev_replies); // rtc x2, entropy, block read
    try testing.expectEqual(@as(u64, 0), o.stats.lost);
}

test "peripheral row is deterministic: same seed, same transcript" {
    var opts = clean_fabric;
    opts.seed = 99;
    var a = try asm_run.simulate(testing.allocator, &asm_src.periph, opts);
    defer a.deinit();
    var b = try asm_run.simulate(testing.allocator, &asm_src.periph, opts);
    defer b.deinit();
    try testing.expectEqualStrings(a.console.?, b.console.?);
    try testing.expectEqual(a.cycles, b.cycles);
    // …and a different seed draws different entropy.
    opts.seed = 100;
    var c = try asm_run.simulate(testing.allocator, &asm_src.periph, opts);
    defer c.deinit();
    try testing.expect(!std.mem.eql(u8, a.console.?, c.console.?));
}

const dev_token_probe_src =
    \\        .org $1000
    \\        LDA #1
    \\        STA !$2400
    \\        LDA ##$FF00_0000_0000_0000
    \\        STA !$2408
    \\        LDA ##$2500
    \\        STA !$2410
    \\        LDA ##$1_0000_0008
    \\        STA !$2418
    \\        SEND 0
    \\wait:   LSTN 1
    \\        CQPOP 1
    \\        BEQ wait
    \\        STA $840
    \\        HLT
;

test "a device demands its token like any ring: wrong token, reject_capability" {
    const dev6564 = @import("dev.zig");
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
        .max_cycles = 100_000,
    });
    defer m.deinit();
    try m.attachDevice(0xFF00, 0x6564, .{ .console = dev6564.Console.init(testing.allocator) });
    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(0xFF00, 0, 0),
        .rights = .{ .send = true },
        .token = 0xBAD, // a stale capability
    });
    m.setRing(0, 0, ring.slot_sq, .{
        .base = 0x2400,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 4,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    var diag = asm6564.Diagnostic{};
    var out = try asm6564.assemble(testing.allocator, dev_token_probe_src, &diag);
    defer out.deinit();
    m.load(0, out.origin, out.code);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    const word0 = std.mem.readInt(u64, m.cores[0].contexts[0].near[0x840..][0..8], .little);
    try testing.expectEqual(
        @as(u64, @intFromEnum(ring.Status.reject_capability)),
        (word0 >> 8) & 0xFF,
    );
    // Nothing reached the device.
    try testing.expectEqual(@as(usize, 0), m.device(0xFF00).?.console.out.items.len);
    try testing.expectEqual(@as(u64, 0), m.stats.dev_deliveries);
}

// ── The IO plane (§6.5): dies, windows, threads ──────────────────────────

const cluster_mod = @import("cluster.zig");

test "io plane: a reliable send crosses dies through a lossy plane" {
    var cl = try cluster_mod.Cluster.init(testing.allocator, .{
        .dies = 2,
        .die = .{
            .cores = 1,
            .contexts_per_core = 1,
            .ram_size = 0x8000,
            .link = .{ .send_timeout = 6000 },
            .max_cycles = 3_000_000,
        },
        .plane = .{
            .base_latency = 2000,
            .jitter = 500,
            .loss_ppm4k = 1024, // 25% each way, datagrams AND acks
            .dup_ppm4k = 256,
        },
        .seed = 0x5EED,
    });
    defer cl.deinit();
    cl.setRoute(0, 1, 1);
    // The sender's capability differs from an on-die one by ONE byte.
    cl.die(0).setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(0, 0, ring.slot_rx),
        .route = 1,
        .rights = .{ .send = true },
        .token = 0xCAFE,
    });
    wireSender(cl.die(0), 0, 0, 0x2300, 0x2400);
    wireReceiver(cl.die(1), 0, 0, 0x2000, 0x2100, 0xCAFE);
    const sender_src =
        \\        .org $1000
        \\        LDA ##$6564_6564_6564_6564
        \\        STA !$2500
        \\        LDA #1
        \\        STA !$2400
        \\        LDA ##$FF00_0000_0000_0000
        \\        STA !$2408
        \\        LDA ##$2500
        \\        STA !$2410
        \\        LDA ##$42_0000_0008
        \\        STA !$2418
        \\retry:  SEND 0
        \\        LSTN 1
        \\        CQPOP 1
        \\        BEQ retry
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        LSR
        \\        AND #$FF
        \\        CMP #0
        \\        BEQ done                    ; delivered and acknowledged
        \\        CMP #3
        \\        BEQ done                    ; peer stopped listening: it has it
        \\        INC !$22A0
        \\        BRA retry
        \\done:   HLT
    ;
    try assembleInto(cl.die(0), 0, sender_src);
    try assembleInto(cl.die(1), 0, receiver_src);
    try cl.die(0).spawn(0, 0, 0x1000, 0x3000, 0);
    try cl.die(1).spawn(0, 0, 0x1400, 0x3800, 0);

    var out = try cl.run();
    defer out.deinit(testing.allocator);
    try testing.expectEqual(machine.StopReason.all_halted, out.reasons[0]);
    try testing.expectEqual(machine.StopReason.all_halted, out.reasons[1]);
    // The message crossed dies intact.
    const rram = cl.die(1).cores[0].ram;
    try testing.expectEqual(
        @as(u64, 0x6564_6564_6564_6564),
        std.mem.readInt(u64, rram[0x2290 - machine.ram_base ..][0..8], .little),
    );
    try testing.expect(out.plane.grams >= 1);
    try testing.expect(out.plane.acks >= 1);
}

test "io plane: the dies ring — same program bytes, one route byte" {
    const o = try @import("demo_dies.zig").simulate(testing.allocator, .{
        .dies = 2,
        .nodes = 8,
        .laps = 3,
        .parallel = false,
    });
    defer o.deinit(testing.allocator);
    try testing.expect(o.exactly_one_finisher);
    try testing.expect(o.finisher_is_origin);
    try testing.expectEqual(@as(u64, 48), o.passes);
    try testing.expectEqual(@as(u64, 6), o.crossings);
    try testing.expectEqual(@as(u64, 6), o.plane.grams);
    try testing.expectEqual(@as(u64, 0), o.plane.lost);
}

test "io plane: bit-identical at any thread count" {
    const seq = try @import("demo_dies.zig").simulate(testing.allocator, .{
        .dies = 4,
        .nodes = 20,
        .laps = 5,
        .parallel = false,
    });
    defer seq.deinit(testing.allocator);
    const par = try @import("demo_dies.zig").simulate(testing.allocator, .{
        .dies = 4,
        .nodes = 20,
        .laps = 5,
        .parallel = true,
    });
    defer par.deinit(testing.allocator);
    try testing.expectEqual(seq.cycles, par.cycles);
    try testing.expectEqual(seq.windows, par.windows);
    try testing.expectEqual(seq.instructions, par.instructions);
    try testing.expectEqual(seq.plane.grams, par.plane.grams);
    try testing.expectEqual(seq.plane.acks, par.plane.acks);
    try testing.expectEqualSlices(machine.StopReason, seq.reasons, par.reasons);
    try testing.expect(par.exactly_one_finisher and par.finisher_is_origin);
}

test "io plane: a route with no path times out honestly" {
    var cl = try cluster_mod.Cluster.init(testing.allocator, .{
        .dies = 2,
        .die = .{
            .cores = 1,
            .contexts_per_core = 1,
            .ram_size = 0x8000,
            .max_cycles = 100_000,
        },
    });
    defer cl.deinit();
    // No setRoute: route byte 1 leads nowhere — the plane's black hole.
    cl.die(0).setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(0, 0, ring.slot_rx),
        .route = 1,
        .rights = .{ .send = true },
        .token = 0,
    });
    wireSender(cl.die(0), 0, 0, 0x2300, 0x2400);
    try assembleInto(cl.die(0), 0, dev_token_probe_src);
    try cl.die(0).spawn(0, 0, 0x1000, 0x3000, 0);
    var out = try cl.run();
    defer out.deinit(testing.allocator);
    try testing.expectEqual(machine.StopReason.all_halted, out.reasons[0]);
    const word0 = std.mem.readInt(u64, cl.die(0).cores[0].contexts[0].near[0x840..][0..8], .little);
    try testing.expectEqual(
        @as(u64, @intFromEnum(ring.Status.timeout)),
        (word0 >> 8) & 0xFF,
    );
    try testing.expectEqual(@as(u64, 1), out.plane.unroutable);
}

test "io plane: busy mode — local rings finish on every die, still bit-identical" {
    const seq = try @import("demo_dies.zig").simulate(testing.allocator, .{
        .dies = 3,
        .nodes = 10,
        .laps = 2,
        .busy = 20,
        .parallel = false,
    });
    defer seq.deinit(testing.allocator);
    const par = try @import("demo_dies.zig").simulate(testing.allocator, .{
        .dies = 3,
        .nodes = 10,
        .laps = 2,
        .busy = 20,
        .parallel = true,
    });
    defer par.deinit(testing.allocator);
    try testing.expect(seq.exactly_one_finisher and seq.finisher_is_origin);
    try testing.expect(seq.busy_rings_finished);
    try testing.expectEqual(seq.cycles, par.cycles);
    try testing.expectEqual(seq.instructions, par.instructions);
    try testing.expectEqual(seq.windows, par.windows);
    try testing.expect(par.busy_rings_finished);
}

test "churn: LFSR sweep counts every line, threaded same as sequential" {
    const seq = try @import("demo_churn.zig").simulate(testing.allocator, .{
        .dies = 2,
        .stripe_mb = 2,
        .sweeps = 2,
        .parallel = false,
    });
    defer seq.deinit(testing.allocator);
    try testing.expect(seq.verified);
    const par = try @import("demo_churn.zig").simulate(testing.allocator, .{
        .dies = 2,
        .stripe_mb = 2,
        .sweeps = 2,
        .parallel = true,
    });
    defer par.deinit(testing.allocator);
    try testing.expect(par.verified);
    try testing.expectEqual(seq.cycles, par.cycles);
    try testing.expectEqual(
        seq.die_stats[0].stats.instructions,
        par.die_stats[0].stats.instructions,
    );
}

// ── The socket bridge (§6.5 across host processes) ───────────────────────

const bridge_mod = @import("bridge.zig");
const demo_net = @import("demo_net.zig");

const NetSide = struct {
    out: ?demo_net.Outcome = null,
    err: ?anyerror = null,
};

fn netConnector(port: u16, parallel: bool, res: *NetSide) void {
    var br = bridge_mod.Bridge.connect("127.0.0.1", port) catch |e| {
        res.err = e;
        return;
    };
    defer br.deinit();
    res.out = demo_net.simulate(testing.allocator, .{
        .role = .connector,
        .dies = 2,
        .nodes = 8,
        .laps = 3,
        .parallel = parallel,
    }, &br) catch |e| {
        res.err = e;
        return;
    };
}

fn runFederation(parallel: bool) !struct { l: demo_net.Outcome, c: demo_net.Outcome } {
    var server = try bridge_mod.Bridge.listenOn(0);
    defer server.deinit();
    const port = server.listen_address.getPort();
    var side = NetSide{};
    const t = try std.Thread.spawn(.{}, netConnector, .{ port, parallel, &side });
    var br = try bridge_mod.Bridge.accept(&server);
    defer br.deinit();
    const lout = demo_net.simulate(testing.allocator, .{
        .role = .listener,
        .dies = 2,
        .nodes = 8,
        .laps = 3,
        .parallel = parallel,
    }, &br);
    t.join();
    if (side.err) |e| {
        if (lout) |o| o.deinit(testing.allocator) else |_| {}
        return e;
    }
    return .{ .l = try lout, .c = side.out.? };
}

test "socket bridge: the ring crosses a real socket and comes home" {
    const f = try runFederation(false);
    defer f.l.deinit(testing.allocator);
    defer f.c.deinit(testing.allocator);
    try testing.expect(f.l.finished_here);
    try testing.expect(!f.c.finished_here);
    try testing.expectEqual(f.l.windows, f.c.windows); // lock-step agreed
    try testing.expectEqual(@as(u64, 96), f.l.passes); // 2 x 2 x 8 x 3
    // Each side egressed half the crossings, and nothing vanished.
    try testing.expectEqual(@as(u64, 6), f.l.plane.grams);
    try testing.expectEqual(@as(u64, 6), f.c.plane.grams);
    try testing.expectEqual(@as(u64, 0), f.l.plane.lost + f.c.plane.lost);
}

test "socket bridge: the federation replays bit-identically, threaded or not" {
    const a = try runFederation(false);
    defer a.l.deinit(testing.allocator);
    defer a.c.deinit(testing.allocator);
    const b = try runFederation(false);
    defer b.l.deinit(testing.allocator);
    defer b.c.deinit(testing.allocator);
    const p = try runFederation(true);
    defer p.l.deinit(testing.allocator);
    defer p.c.deinit(testing.allocator);
    // Same seeds, same federation → same virtual history, every time,
    // at any thread count, regardless of real socket timing.
    try testing.expectEqual(a.l.cycles, b.l.cycles);
    try testing.expectEqual(a.l.cycles, p.l.cycles);
    try testing.expectEqual(a.c.cycles, p.c.cycles);
    try testing.expectEqual(a.l.windows, p.l.windows);
    try testing.expectEqual(
        a.l.die_stats[0].stats.instructions,
        p.l.die_stats[0].stats.instructions,
    );
    try testing.expect(a.l.finished_here and b.l.finished_here and p.l.finished_here);
}

// ── The net device: HTTP against a local server, hermetically ───────────

fn miniHttpServer(server: *std.net.Server, err: *?anyerror) void {
    const conn = server.accept() catch |e| {
        err.* = e;
        return;
    };
    defer conn.stream.close();
    var buf: [512]u8 = undefined;
    _ = conn.stream.read(&buf) catch |e| {
        err.* = e;
        return;
    };
    conn.stream.writeAll(
        "HTTP/1.1 200 OK\r\nContent-Length: 21\r\nConnection: close\r\n\r\nHELLO FROM THE OUTSIDE",
    ) catch |e| {
        err.* = e;
        return;
    };
}

test "net device: http_get.asm fetches from a real (local) TCP server" {
    var server = try bridge_mod.Bridge.listenOn(0);
    defer server.deinit();
    const port = server.listen_address.getPort();
    var serr: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, miniHttpServer, .{ &server, &serr });
    const o = try @import("demo_web.zig").simulate(testing.allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .path = "/hello",
    });
    defer testing.allocator.free(o.text);
    t.join();
    try testing.expect(serr == null);
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expect(std.mem.startsWith(u8, o.text, "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.indexOf(u8, o.text, "HELLO FROM THE OUTSIDE") != null);
    try testing.expect(o.stats.dev_replies >= 2); // the open reply + data
}

test "counted shifts: LSR #n / ASL #n match n single-bit shifts" {
    const src =
        \\        .org $1000
        \\        LDA ##$1234_5678_9ABC_DEF0
        \\        LSR #32
        \\        STA !$2280          ; high half
        \\        LDA ##$8000_0000_0000_0001
        \\        ASL #1
        \\        STA !$2288          ; carry out, bit gone
        \\        LDA #1
        \\        ASL #63
        \\        STA !$2290          ; 1 << 63
        \\        LDA ##$FF
        \\        LSR #0
        \\        STA !$2298          ; count 0: untouched
        \\        HLT
    ;
    var m = try Machine.init(testing.allocator, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
    });
    defer m.deinit();
    try assembleInto(&m, 0, src);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    try testing.expectEqual(machine.StopReason.all_halted, try m.run());
    const ram = m.cores[0].ram;
    const word = struct {
        fn at(r: []u8, addr: u64) u64 {
            return std.mem.readInt(u64, r[addr - machine.ram_base ..][0..8], .little);
        }
    }.at;
    try testing.expectEqual(@as(u64, 0x1234_5678), word(ram, 0x2280));
    try testing.expectEqual(@as(u64, 2), word(ram, 0x2288));
    try testing.expectEqual(@as(u64, 1) << 63, word(ram, 0x2290));
    try testing.expectEqual(@as(u64, 0xFF), word(ram, 0x2298));
}
