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

// ── Armstrong's ring (Programming Erlang, ch. 12) ────────────────────────

test "armstrong ring: N x M passes, message comes home to node 0" {
    const o = try @import("demo_ring.zig").simulate(testing.allocator, .{
        .nodes = 8,
        .laps = 4,
    });
    try testing.expectEqual(@as(u64, 32), o.passes);
    try testing.expect(o.exactly_one_finisher);
    try testing.expect(o.finisher_is_node0);
    try testing.expectEqual(machine.StopReason.deadlock, o.reason); // quiesced
}

test "armstrong ring: steady-state cost per pass stays two-digit" {
    const o = try @import("demo_ring.zig").simulate(testing.allocator, .{
        .nodes = 64,
        .laps = 20,
    });
    try testing.expect(o.exactly_one_finisher and o.finisher_is_node0);
    // The §2.2 claim, as a regression guard: actor-to-actor messaging on one
    // core, scheduler included, stays under 100 cycles per pass.
    try testing.expect(o.cycles_per_pass < 100);
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
    const o = try @import("demo_ring.zig").simulate(testing.allocator, .{
        .nodes = 200,
        .laps = 10,
    });
    try testing.expectEqual(@as(u64, 2000), o.passes);
    try testing.expect(o.exactly_one_finisher and o.finisher_is_node0);
    try testing.expect(o.cycles_per_pass < 100);
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
    const o = try @import("demo_bigbrother.zig").simulate(testing.allocator, .{
        .senders = 600,
        .loss_ppm4k = 0,
    });
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqual(@as(u64, 600), o.received);
    try testing.expectEqual(o.expected_sum, o.sum);
    try testing.expect(o.stats.rejects > 0); // saturation really happened
    try testing.expectEqual(@as(u64, 0), o.stats.cq_overflows);
}

test "big brother: sub-saturation flood delivers first time" {
    const o = try @import("demo_bigbrother.zig").simulate(testing.allocator, .{
        .senders = 200,
        .loss_ppm4k = 0,
    });
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqual(@as(u64, 200), o.received);
    try testing.expectEqual(o.expected_sum, o.sum);
}

test "fork-join matrix at full scale: 8x125, forked, relayed, joined" {
    const o = try @import("demo_forkjoin.zig").simulate(testing.allocator, .{
        .lieutenants = 8,
        .workers = 125,
    });
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqual(@as(u64, 1000), o.received);
    try testing.expectEqual(o.expected_sum, o.sum);
    try testing.expectEqual(@as(u64, 7), o.stats.chain_fires);
    try testing.expectEqual(@as(u64, 0), o.stats.cq_overflows);
}

// ── The peripheral row (§7) ──────────────────────────────────────────────

test "hello: the console device hears the machine's first words" {
    const o = try @import("demo_hello.zig").simulate(testing.allocator, .{});
    defer testing.allocator.free(o.text);
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqualStrings("HELLO, WORLD - THE 6564 SPEAKS.\n", o.text);
    try testing.expectEqual(@as(u64, 1), o.stats.dev_deliveries);
    try testing.expectEqual(@as(u64, 0), o.stats.dev_replies);
}

test "peripheral row: console, entropy, rtc and block all answer" {
    const o = try @import("demo_periph.zig").simulate(testing.allocator, .{});
    defer testing.allocator.free(o.text);
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expect(o.block_ok);
    try testing.expect(std.mem.startsWith(u8, o.text, "6564 PERIPHERAL BUS CHECK\n"));
    try testing.expect(std.mem.indexOf(u8, o.text, "ENTROPY ") != null);
    try testing.expect(std.mem.indexOf(u8, o.text, "CYCLES ") != null);
    // The program's RTC arithmetic must agree with the fabric's clock:
    // elapsed is bounded by the whole run.
    try testing.expect(o.elapsed > 0 and o.elapsed < o.cycles);
    try testing.expectEqual(@as(u64, 4), o.stats.dev_replies); // rtc x2, entropy, block read
    try testing.expectEqual(@as(u64, 0), o.stats.lost);
}

test "peripheral row is deterministic: same seed, same transcript" {
    const a = try @import("demo_periph.zig").simulate(testing.allocator, .{ .seed = 99 });
    defer testing.allocator.free(a.text);
    const b = try @import("demo_periph.zig").simulate(testing.allocator, .{ .seed = 99 });
    defer testing.allocator.free(b.text);
    try testing.expectEqualStrings(a.text, b.text);
    try testing.expectEqual(a.cycles, b.cycles);
    // …and a different seed draws different entropy.
    const c = try @import("demo_periph.zig").simulate(testing.allocator, .{ .seed = 100 });
    defer testing.allocator.free(c.text);
    try testing.expect(!std.mem.eql(u8, a.text, c.text));
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
