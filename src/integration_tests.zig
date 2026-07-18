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
    const src = @embedFile("programs/pingpong.joe");
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
    const src = @embedFile("programs/pingpong.joe");
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
    const base = @embedFile("programs/pingpong.joe");
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
    const src = @embedFile("programs/ring.joe");
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
    const src = @embedFile("programs/keys.joe");
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

test "A2.5: store.joe — the substrate's shape, polyfilled by an ordinary actor" {
    // §7.5's proof obligation, discharged: the Put/Get/Del contract with
    // canonical struple keys, served entirely from joe — byte equality,
    // copy, overwrite, delete, honest misses. Scorched and not.
    const joe_run = @import("joe_run.zig");
    const src = @embedFile("programs/store.joe");
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
    const src = @embedFile("programs/crunch.joe");
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
        @embedFile("programs/pingpong.joe"),
        @embedFile("programs/ring.joe"),
        @embedFile("programs/crunch.joe"),
        @embedFile("programs/supervise.joe"),
        @embedFile("programs/scatter.joe"),
        @embedFile("programs/pipeline.joe"),
        @embedFile("programs/hello.joe"),
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
        .{ .src = @embedFile("programs/pingpong.joe"), .actors = &.{ "Pinger", "Ponger" } },
        .{ .src = @embedFile("programs/ring.joe"), .actors = &.{ "Head", "Node" } },
        .{ .src = @embedFile("programs/crunch.joe"), .actors = &.{ "Cruncher", "Sink" } },
        .{ .src = @embedFile("programs/supervise.joe"), .actors = &.{ "Boss", "Griefer", "Sleeper" } },
        .{ .src = @embedFile("programs/forkjoin.joe"), .actors = &.{ "Root", "Lieutenant", "Worker" } },
        .{ .src = @embedFile("programs/pipeline.joe"), .actors = &.{ "Source", "Stage", "Sink" } },
        .{ .src = @embedFile("programs/hello.joe"), .actors = &.{"Greeter"} },
        .{ .src = @embedFile("programs/keys.joe"), .actors = &.{ "Asker", "Router" } },
        .{ .src = @embedFile("programs/store.joe"), .actors = &.{ "Store", "Client" } },
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
    const src = @embedFile("programs/supervise.joe");
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
    const src = @embedFile("programs/crunch.joe");
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
    const src = @embedFile("programs/scatter.joe");
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
    const src = @embedFile("programs/pipeline.joe");
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
    const src = @embedFile("programs/hello.joe");
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
    // forkjoin.joe); the suite runs the same shape at 2x20 so Debug
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

test "mandel: the whole picture matches the host-f64 oracle, row for row" {
    // 1,408 points, up to 16 iterations each — thousands of FMUL/FADD/
    // FSUB/FCMP results, every one of which must round exactly as the
    // host's IEEE doubles do, or a character somewhere is wrong.
    const demo_mandel = @import("demo_mandel.zig");
    const o = try demo_mandel.simulate(testing.allocator, .{});
    defer testing.allocator.free(o.text);
    try testing.expectEqual(machine.StopReason.all_halted, o.reason);
    try testing.expectEqual(
        @as(usize, (demo_mandel.cols + 1) * demo_mandel.rows),
        o.text.len,
    );
    for (0..demo_mandel.rows) |r| {
        const expected = try demo_mandel.oracleRow(testing.allocator, r);
        defer testing.allocator.free(expected);
        const got = o.text[r * (demo_mandel.cols + 1) ..][0 .. demo_mandel.cols + 1];
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
