//! The 6564-Net ISA table — the single source of truth.
//!
//! Everything that knows about instruction encoding derives from `table` at
//! comptime: the simulator's decoder, the assembler's matcher, and the
//! disassembler. Adding an instruction is one line here; a duplicate opcode
//! byte is a compile error.
//!
//! Encoding heritage: instructions inherited from the 6502/65C02 keep their
//! classic opcode bytes (LDA #imm is still 0xA9; the 65C02's zp-indirect
//! column, e.g. STA (zp) = 0x92, becomes our near-indirect). The 6564's new
//! I/O and concurrency instructions occupy the 0x?7 column, which NMOS 6502
//! never defined. Immediate-64 variants sit in the otherwise-free 0x?3 column.
//!
//! Widths: the 6564 is a 64-bit machine. All loads, stores, arithmetic and
//! comparisons operate on full 64-bit words; `#imm8` operands sign-extend.
//! Branch displacements are signed 16-bit, relative to the first byte of the
//! *next* instruction (6502 convention, widened).

const std = @import("std");

/// Addressing modes. Operand bytes follow the opcode byte, little-endian.
pub const Mode = enum {
    /// No operand (implied), e.g. `YLD`.
    impl,
    /// Operates on the accumulator, e.g. `ASL`.
    acc,
    /// 1-byte immediate, sign-extended to 64 bits: `LDA #$10`.
    imm8,
    /// 8-byte immediate: `LDA ##$DEAD_BEEF_0000_0001`.
    imm64,
    /// 2-byte near-page offset (< 4 KB): `LDA $0F8`.
    near,
    /// Near indexed by X: `LDA $0F8,X`. Effective near offset wraps mod 4 KB.
    near_x,
    /// Near indexed by Y: `LDX $0F8,Y`.
    near_y,
    /// 8-byte absolute address: `LDA !$1_0000`.
    abs,
    /// Indirect through a near-page pointer: `LDA ($10)`.
    ind,
    /// Indirect through near-page pointer, post-indexed by Y: `LDA ($10),Y`.
    ind_y,
    /// 2-byte signed displacement from next instruction: branches, `CONT`.
    rel16,
    /// 1-byte queue-pair descriptor index (near-page descriptor table slot).
    desc,
    /// CAPLD only: 2-byte PTT slot index + 2-byte near offset of a 32-byte
    /// PTT entry image: `CAPLD 3, ($40)`.
    caps,

    pub fn operandSize(self: Mode) u8 {
        return switch (self) {
            .impl, .acc => 0,
            .imm8, .desc => 1,
            .near, .near_x, .near_y, .ind, .ind_y, .rel16 => 2,
            .caps => 4,
            .imm64, .abs => 8,
        };
    }
};

pub const Mnemonic = enum {
    // Loads / stores
    lda,
    ldx,
    ldy,
    sta,
    stx,
    sty,
    // Register transfers
    tax,
    txa,
    tay,
    tya,
    tsx,
    txs,
    // Arithmetic / logic (A ⟵ A op M)
    adc,
    sbc,
    and_,
    ora,
    eor,
    cmp,
    cpx,
    cpy,
    asl,
    lsr,
    rol,
    ror,
    inc,
    dec,
    inx,
    iny,
    dex,
    dey,
    // Control flow
    jmp,
    jsr,
    rts,
    bpl,
    bmi,
    bvc,
    bvs,
    bcc,
    bcs,
    bne,
    beq,
    bra,
    // Stack
    pha,
    pla,
    phx,
    plx,
    phy,
    ply,
    php,
    plp,
    // Flags
    clc,
    sec,
    clv,
    // Misc
    nop,
    brk,
    hlt,
    // 6564-Net I/O and concurrency (§7 of the architecture doc)
    txr,
    send,
    recv,
    lstn,
    cont,
    yld,
    cqpop,
    capld,

    /// Assembly spelling ("and_" is spelled "AND").
    pub fn spelling(self: Mnemonic) []const u8 {
        return switch (self) {
            .and_ => "AND",
            inline else => |m| comptime blk: {
                var buf: [@tagName(m).len]u8 = undefined;
                _ = std.ascii.upperString(&buf, @tagName(m));
                const frozen = buf;
                break :blk &frozen;
            },
        };
    }
};

pub const Encoding = struct {
    mnemonic: Mnemonic,
    mode: Mode,
    opcode: u8,
    /// Base cycle cost. Taken branches add 1; queue ops that park add nothing
    /// (parking is free — the context simply leaves the run queue).
    cycles: u8,

    pub fn size(self: Encoding) u8 {
        return 1 + self.mode.operandSize();
    }
};

fn e(mnemonic: Mnemonic, mode: Mode, opcode: u8, cycles: u8) Encoding {
    return .{ .mnemonic = mnemonic, .mode = mode, .opcode = opcode, .cycles = cycles };
}

/// The ISA. One row per (mnemonic, mode) pair.
pub const table = [_]Encoding{
    // ── Loads ────────────────────────────────────────────────────────────
    e(.lda, .imm8, 0xA9, 2),   e(.lda, .imm64, 0xA3, 3),
    e(.lda, .near, 0xA5, 3),   e(.lda, .near_x, 0xB5, 3),
    e(.lda, .abs, 0xAD, 4),    e(.lda, .ind, 0xB2, 5),
    e(.lda, .ind_y, 0xB1, 5),  e(.ldx, .imm8, 0xA2, 2),
    e(.ldx, .imm64, 0xA7, 3),  e(.ldx, .near, 0xA6, 3),
    e(.ldx, .near_y, 0xB6, 3), e(.ldx, .abs, 0xAE, 4),
    e(.ldy, .imm8, 0xA0, 2),   e(.ldy, .imm64, 0xAB, 3),
    e(.ldy, .near, 0xA4, 3),   e(.ldy, .near_x, 0xB4, 3),
    e(.ldy, .abs, 0xAC, 4),
    // ── Stores ───────────────────────────────────────────────────────────
       e(.sta, .near, 0x85, 3),
    e(.sta, .near_x, 0x95, 3), e(.sta, .abs, 0x8D, 4),
    e(.sta, .ind, 0x92, 5),    e(.sta, .ind_y, 0x91, 5),
    e(.stx, .near, 0x86, 3),   e(.stx, .abs, 0x8E, 4),
    e(.sty, .near, 0x84, 3),   e(.sty, .abs, 0x8C, 4),
    // ── Transfers ────────────────────────────────────────────────────────
    e(.tax, .impl, 0xAA, 1),   e(.txa, .impl, 0x8A, 1),
    e(.tay, .impl, 0xA8, 1),   e(.tya, .impl, 0x98, 1),
    e(.tsx, .impl, 0xBA, 1),   e(.txs, .impl, 0x9A, 1),
    // ── Arithmetic / logic ───────────────────────────────────────────────
    e(.adc, .imm8, 0x69, 2),   e(.adc, .imm64, 0x63, 3),
    e(.adc, .near, 0x65, 3),   e(.adc, .near_x, 0x75, 3),
    e(.adc, .abs, 0x6D, 4),    e(.adc, .ind, 0x72, 5),
    e(.adc, .ind_y, 0x71, 5),  e(.sbc, .imm8, 0xE9, 2),
    e(.sbc, .imm64, 0xE3, 3),  e(.sbc, .near, 0xE5, 3),
    e(.sbc, .near_x, 0xF5, 3), e(.sbc, .abs, 0xED, 4),
    e(.sbc, .ind, 0xF2, 5),    e(.sbc, .ind_y, 0xF1, 5),
    e(.and_, .imm8, 0x29, 2),  e(.and_, .imm64, 0x23, 3),
    e(.and_, .near, 0x25, 3),  e(.and_, .near_x, 0x35, 3),
    e(.and_, .abs, 0x2D, 4),   e(.and_, .ind, 0x32, 5),
    e(.and_, .ind_y, 0x31, 5), e(.ora, .imm8, 0x09, 2),
    e(.ora, .imm64, 0x03, 3),  e(.ora, .near, 0x05, 3),
    e(.ora, .near_x, 0x15, 3), e(.ora, .abs, 0x0D, 4),
    e(.ora, .ind, 0x12, 5),    e(.ora, .ind_y, 0x11, 5),
    e(.eor, .imm8, 0x49, 2),   e(.eor, .imm64, 0x43, 3),
    e(.eor, .near, 0x45, 3),   e(.eor, .near_x, 0x55, 3),
    e(.eor, .abs, 0x4D, 4),    e(.eor, .ind, 0x52, 5),
    e(.eor, .ind_y, 0x51, 5),  e(.cmp, .imm8, 0xC9, 2),
    e(.cmp, .imm64, 0xC3, 3),  e(.cmp, .near, 0xC5, 3),
    e(.cmp, .near_x, 0xD5, 3), e(.cmp, .abs, 0xCD, 4),
    e(.cmp, .ind, 0xD2, 5),    e(.cmp, .ind_y, 0xD1, 5),
    e(.cpx, .imm8, 0xE0, 2),   e(.cpx, .near, 0xE4, 3),
    e(.cpx, .abs, 0xEC, 4),    e(.cpy, .imm8, 0xC0, 2),
    e(.cpy, .near, 0xC4, 3),   e(.cpy, .abs, 0xCC, 4),
    // ── Shifts (accumulator) ─────────────────────────────────────────────
    e(.asl, .acc, 0x0A, 1),    e(.lsr, .acc, 0x4A, 1),
    e(.rol, .acc, 0x2A, 1),    e(.ror, .acc, 0x6A, 1),
    // ── Increment / decrement ────────────────────────────────────────────
    e(.inc, .acc, 0x1A, 1),    e(.inc, .near, 0xE6, 4),
    e(.inc, .abs, 0xEE, 5),    e(.dec, .acc, 0x3A, 1),
    e(.dec, .near, 0xC6, 4),   e(.dec, .abs, 0xCE, 5),
    e(.inx, .impl, 0xE8, 1),   e(.iny, .impl, 0xC8, 1),
    e(.dex, .impl, 0xCA, 1),   e(.dey, .impl, 0x88, 1),
    // ── Control flow ─────────────────────────────────────────────────────
    e(.jmp, .abs, 0x4C, 3),    e(.jmp, .ind, 0x6C, 5),
    e(.jsr, .abs, 0x20, 5),    e(.rts, .impl, 0x60, 5),
    e(.bpl, .rel16, 0x10, 2),  e(.bmi, .rel16, 0x30, 2),
    e(.bvc, .rel16, 0x50, 2),  e(.bvs, .rel16, 0x70, 2),
    e(.bcc, .rel16, 0x90, 2),  e(.bcs, .rel16, 0xB0, 2),
    e(.bne, .rel16, 0xD0, 2),  e(.beq, .rel16, 0xF0, 2),
    e(.bra, .rel16, 0x80, 2),
    // ── Stack ────────────────────────────────────────────────────────────
     e(.pha, .impl, 0x48, 2),
    e(.pla, .impl, 0x68, 2),   e(.phx, .impl, 0xDA, 2),
    e(.plx, .impl, 0xFA, 2),   e(.phy, .impl, 0x5A, 2),
    e(.ply, .impl, 0x7A, 2),   e(.php, .impl, 0x08, 2),
    e(.plp, .impl, 0x28, 2),
    // ── Flags ────────────────────────────────────────────────────────────
      e(.clc, .impl, 0x18, 1),
    e(.sec, .impl, 0x38, 1),   e(.clv, .impl, 0xB8, 1),
    // ── Misc ─────────────────────────────────────────────────────────────
    e(.nop, .impl, 0xEA, 1),
    e(.brk, .impl, 0x00, 1), // software fault trap: halts the context
    e(.hlt, .impl, 0xDB, 1), // 65C02 STP's slot: halt this context, done
    // ── 6564-Net I/O and concurrency (the 0x?7 column) ───────────────────
    e(.txr, .ind, 0x07, 4), //  TXR (ptr),A — single-register datagram
    e(.send, .desc, 0x17, 4), // SEND desc  — post SQ descriptor, DMA streams
    e(.recv, .desc, 0x27, 4), // RECV desc  — post landing buffer to RX ring
    e(.lstn, .desc, 0x37, 2), // LSTN desc  — park until ring non-empty
    e(.cont, .rel16, 0x47, 2), // CONT addr — push continuation on run queue
    e(.yld, .impl, 0x57, 1), //  YLD        — rotate to next runnable
    e(.cqpop, .desc, 0x67, 3), // CQPOP desc — pop completion into A, X
    e(.capld, .caps, 0x77, 6), // CAPLD slot,(near) — privileged PTT load
};

/// 256-entry decode table, generated at comptime. `null` = undefined opcode
/// (architectural fault, honest per the spec — no silent NOPs).
pub const decode: [256]?Encoding = blk: {
    var d: [256]?Encoding = .{null} ** 256;
    for (table) |enc| {
        if (d[enc.opcode] != null)
            @compileError(std.fmt.comptimePrint(
                "duplicate opcode 0x{X:0>2}",
                .{enc.opcode},
            ));
        d[enc.opcode] = enc;
    }
    break :blk d;
};

/// Find the encoding for a (mnemonic, mode) pair; null if that pairing
/// doesn't exist in the ISA. Used by the assembler.
pub fn lookup(mnemonic: Mnemonic, mode: Mode) ?Encoding {
    inline for (table) |enc| {
        if (enc.mnemonic == mnemonic and enc.mode == mode) return enc;
    }
    return null;
}

// ── Status flags ─────────────────────────────────────────────────────────

pub const Flags = packed struct(u8) {
    c: bool = false, // carry
    z: bool = false, // zero
    _pad: u4 = 0,
    v: bool = false, // overflow
    n: bool = false, // negative (bit 63)

    pub fn setNZ(self: *Flags, value: u64) void {
        self.z = value == 0;
        self.n = (value >> 63) != 0;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "decode table round-trips every encoding" {
    for (table) |enc| {
        const got = decode[enc.opcode] orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(enc.mnemonic, got.mnemonic);
        try std.testing.expectEqual(enc.mode, got.mode);
    }
}

test "classic 6502 opcodes are honored" {
    try std.testing.expectEqual(Mnemonic.lda, decode[0xA9].?.mnemonic);
    try std.testing.expectEqual(Mode.imm8, decode[0xA9].?.mode);
    try std.testing.expectEqual(Mnemonic.jsr, decode[0x20].?.mnemonic);
    try std.testing.expectEqual(Mnemonic.beq, decode[0xF0].?.mnemonic);
    try std.testing.expectEqual(Mnemonic.sta, decode[0x92].?.mnemonic); // 65C02 (zp)
}

test "spelling" {
    try std.testing.expectEqualStrings("AND", Mnemonic.and_.spelling());
    try std.testing.expectEqualStrings("CQPOP", Mnemonic.cqpop.spelling());
}

test "flags setNZ" {
    var p = Flags{};
    p.setNZ(0);
    try std.testing.expect(p.z and !p.n);
    p.setNZ(@as(u64, 1) << 63);
    try std.testing.expect(!p.z and p.n);
}
