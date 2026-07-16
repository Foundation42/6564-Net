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
        \\        LDA ##$FF00_0000_0000_0000  ; dst: PTT slot 0
        \\        STA !$2400                  ; word0: dst
        \\        LDA ##$2500
        \\        STA !$2408                  ; word1: src buffer
        \\        LDA #8
        \\        STA !$2410                  ; word2: length (owned bit clear)
        \\        LDA #$42
        \\        STA !$2418                  ; word3: cookie
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
            \\        LDA ##$FF00_0000_0000_0000
            \\        STA !$2400
            \\        LDA ##$2500
            \\        STA !$2408
            \\        LDA #8
            \\        STA !$2410
            \\        LDA #7
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

// ── Phase 3: supervision ─────────────────────────────────────────────────

test "supervision tree: restarts, budgets, watchdog, accumulated work" {
    const o = try @import("demo_supervise.zig").simulate(testing.allocator, false);
    // Reliable workers met quota and exited clean.
    try testing.expectEqual(@as(u64, 12), o.progress[1]);
    try testing.expectEqual(@as(u64, 12), o.progress[3]);
    // The crasher produced 5 items per incarnation across 4 lives (initial +
    // 3 restarts) — its RAM progress cell survived every SPWN.
    try testing.expectEqual(@as(u64, 20), o.progress[2]);
    // The hanger produced 3 items per incarnation across 3 lives (initial +
    // 2 restarts); each life ended in a watchdog trip, not a BRK.
    try testing.expectEqual(@as(u64, 9), o.progress[4]);
    try testing.expectEqual(@as(u64, 3), o.watchdog_trips);
    try testing.expectEqual(machine.Fault.watchdog, o.hanger_fault);
    // Total restarts across both budgets.
    try testing.expectEqual(@as(u64, 5), o.restarts);
    try testing.expect(o.supervisor_halted);
    // Abandoned honestly: both unreliable workers' last lives stay faulted.
    try testing.expectEqual(machine.CtxState.faulted, o.crasher_state);
    try testing.expectEqual(machine.CtxState.faulted, o.hanger_state);
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
    const o = try @import("demo_pipeline.zig").simulate(testing.allocator, .{
        .seed = 0x6564,
        .loss_ppm4k = 1024,
        .items = 12,
        .stages = 2,
    });
    try testing.expectEqual(@as(u64, 13), o.consumed); // 12 items + DONE
    try testing.expectEqual(@as(u64, 0), o.verify_errors);
    try testing.expectEqual(o.expected_checksum, o.checksum);
    try testing.expect(o.source_halted);
    try testing.expect(o.stages_done);
    // Quiesced, not timed out: the lame-duck shutdown converged.
    try testing.expectEqual(machine.StopReason.deadlock, o.reason);
    try testing.expect(o.stats.lost > 0); // the fabric really was hostile
}

test "pipeline: zero stages (source direct to sink)" {
    const o = try @import("demo_pipeline.zig").simulate(testing.allocator, .{
        .seed = 7,
        .loss_ppm4k = 512,
        .items = 8,
        .stages = 0,
    });
    try testing.expectEqual(@as(u64, 9), o.consumed);
    try testing.expectEqual(@as(u64, 0), o.verify_errors);
    try testing.expectEqual(o.expected_checksum, o.checksum);
    try testing.expect(o.source_halted);
    try testing.expectEqual(machine.StopReason.deadlock, o.reason);
}

// ── Phase 3: scatter-gather ──────────────────────────────────────────────

test "scatter-gather: all results gathered and verified over a lossy fabric" {
    const o = try @import("demo_scatter.zig").simulate(testing.allocator, .{
        .seed = 0x6564,
        .loss_ppm4k = 1024,
        .workers = 6,
    });
    try testing.expectEqual(@as(u64, 6), o.gathered);
    try testing.expectEqual(o.expected_sum, o.sum);
    try testing.expect(o.coordinator_halted);
    try testing.expectEqual(machine.StopReason.deadlock, o.reason); // quiesced
    // The fabric was hostile and the retry loop actually worked for a living.
    try testing.expect(o.stats.lost > 0);
    try testing.expect(o.scatter_sends >= 6);
}

test "scatter-gather: full fan-out saturates the cap-8 fan-in ring" {
    const o = try @import("demo_scatter.zig").simulate(testing.allocator, .{
        .seed = 1,
        .loss_ppm4k = 0,
        .workers = 8,
    });
    try testing.expectEqual(@as(u64, 8), o.gathered);
    try testing.expectEqual(o.expected_sum, o.sum);
    try testing.expect(o.coordinator_halted);
}
