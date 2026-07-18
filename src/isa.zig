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
    spwn,
    wdex,
    // Tier 0 scalar floating point (extended page, prefix $42). FP64 lives
    // in A; FP32 widens on load. IEEE 754, round-to-nearest-even, no
    // FTZ/DAZ, no silent fusion — bit-exact deterministic.
    fadd,
    fsub,
    fmul,
    fdiv,
    fsqrt,
    fcmp,
    ftoi,
    itof,
    flds,
    fsts,
    // Tier 1 vectors (extended page, the $?7 column — the base page spent
    // its $?7 column on I/O and concurrency; the extended page spends its
    // on the vector unit). V0–V7 × 512-bit, EIGHT f64/u64 lanes, ONE
    // shared file per core, volatile across parks — never banked, never
    // saved, exactly the §1 collapse convention extended to wide state.
    vld, // VLD n     — V[n] ⟵ 64 bytes at [X]
    vst, // VST n     — 64 bytes at [X] ⟵ V[n] (local memory only)
    vbca, // VBCA n   — every lane of V[n] ⟵ A
    vfadd, // VFADD d, s — lanewise f64, V[d] ⟵ V[d] op V[s]
    vfsub,
    vfmul,
    vfdiv,
    vadd, // VADD d, s — lanewise u64, wrapping
    vand,
    vora,
    veor,
    vradd, // VRADD n — A ⟵ pairwise-tree f64 sum: ((l0+l1)+(l2+l3))+((l4+l5)+(l6+l7))
    vrmax, // VRMAX n — A ⟵ lanewise max, lane 0 bias on ties, NaN propagates
    vrmin,
    vperm, // VPERM d, s — V[d].lane[i] ⟵ V[s].lane[A.byte[i] & 7]
    // One-byte vectored calls through the per-context MACTAB (near page
    // $F80–$FFF). Semantics are exactly JSR [MACTAB + n*8]; the slot index
    // is the opcode's high nibble. Pre-normative — see the MAC & chains
    // sketch; adoption rides on the measurement plan.
    mac,

    /// Assembly spelling ("and_" is spelled "AND").
    pub fn spelling(self: Mnemonic) []const u8 {
        return switch (self) {
            .and_ => "AND",
            inline else => |m| comptime blk: {
                @setEvalBranchQuota(8000);
                var buf: [@tagName(m).len]u8 = undefined;
                _ = std.ascii.upperString(&buf, @tagName(m));
                const frozen = buf;
                break :blk &frozen;
            },
        };
    }
};

/// Which opcode page an encoding lives on. The extended page is reached by
/// one prefix byte (`ext_prefix`) — one prefix, one page, done. Non-stacking
/// by hard rule: the prefix byte is undefined ON the extended page, so a
/// second prefix is an honest fault, not a deeper decode.
pub const Page = enum { base, ext };

/// The extended-page prefix: $42 — WDM, the one opcode the 65816 reserved
/// for future expansion when it grew the 6502. The 6564 spends that
/// reservation here.
pub const ext_prefix: u8 = 0x42;

pub const Encoding = struct {
    mnemonic: Mnemonic,
    mode: Mode,
    opcode: u8,
    /// Base cycle cost. Taken branches add 1; queue ops that park add nothing
    /// (parking is free — the context simply leaves the run queue).
    /// Extended-page costs include the prefix fetch.
    cycles: u8,
    page: Page = .base,

    pub fn size(self: Encoding) u8 {
        const prefix: u8 = if (self.page == .ext) 1 else 0;
        return prefix + 1 + self.mode.operandSize();
    }
};

fn e(mnemonic: Mnemonic, mode: Mode, opcode: u8, cycles: u8) Encoding {
    return .{ .mnemonic = mnemonic, .mode = mode, .opcode = opcode, .cycles = cycles };
}

fn x(mnemonic: Mnemonic, mode: Mode, opcode: u8, cycles: u8) Encoding {
    return .{ .mnemonic = mnemonic, .mode = mode, .opcode = opcode, .cycles = cycles, .page = .ext };
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
    // Counted shifts (v2.5): `LSR #n` etc. — a barrel shifter is
    // constant-time silicon, so any count costs 2 cycles. Count is taken
    // mod 64; 0 is a no-op that leaves the flags alone. Carry = the last
    // bit shifted out, exactly as n single-bit shifts would leave it.
    e(.asl, .imm8, 0x0B, 2),   e(.lsr, .imm8, 0x4B, 2),
    e(.rol, .imm8, 0x2B, 2),   e(.ror, .imm8, 0x6B, 2),
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
    // SPWN near — (re)start a sibling context from a near-page spawn block
    // {ctx, entry IP, SP, arg→A}; near,X enables indexed spawn-block tables.
    e(.spwn, .near, 0x87, 6),
    e(.spwn, .near_x, 0x97, 6),
    // WDEX ##n (§5.4) — declare the current burst long: set its remaining
    // watchdog budget to n. Supervisor-bounded: n above the control block's
    // declaration ceiling faults (`wdex_ceiling`) instead of extending the
    // leash. Resets to the base budget at the next park; ##0 cancels the
    // declaration. With no watchdog armed there is no leash to extend —
    // architectural no-op.
    e(.wdex, .imm64, 0xB7, 3),
    // ── MAC: the $?F column, spent whole on one feature ──────────────────
    e(.mac, .impl, 0x0F, 6),
    e(.mac, .impl, 0x1F, 6),
    e(.mac, .impl, 0x2F, 6),
    e(.mac, .impl, 0x3F, 6),
    e(.mac, .impl, 0x4F, 6),
    e(.mac, .impl, 0x5F, 6),
    e(.mac, .impl, 0x6F, 6),
    e(.mac, .impl, 0x7F, 6),
    e(.mac, .impl, 0x8F, 6),
    e(.mac, .impl, 0x9F, 6),
    e(.mac, .impl, 0xAF, 6),
    e(.mac, .impl, 0xBF, 6),
    e(.mac, .impl, 0xCF, 6),
    e(.mac, .impl, 0xDF, 6),
    e(.mac, .impl, 0xEF, 6),
    e(.mac, .impl, 0xFF, 6),
};

/// The extended page (prefix $42): Tier 0 scalar floating point. Layout
/// convention carried over from the base page — each FP op sits in its
/// integer analog's row: FADD in ADC's ($6x), FSUB in SBC's ($Ex), FCMP in
/// CMP's ($Cx); FMUL and FDIV, having no integer analog, borrow AND's ($2x)
/// and EOR's ($4x) rows. Unary ops take the $?A accumulator column. Cycle
/// costs include the prefix fetch; FDIV/FSQRT are long ops, honestly priced.
pub const xtable = [_]Encoding{
    // ── FADD: A ⟵ A + M ─────────────────────────────────────────────────
    x(.fadd, .imm64, 0x63, 6),  x(.fadd, .near, 0x65, 6),
    x(.fadd, .near_x, 0x75, 6), x(.fadd, .abs, 0x6D, 7),
    x(.fadd, .ind, 0x72, 8),    x(.fadd, .ind_y, 0x71, 8),
    // ── FSUB: A ⟵ A − M ─────────────────────────────────────────────────
    x(.fsub, .imm64, 0xE3, 6),  x(.fsub, .near, 0xE5, 6),
    x(.fsub, .near_x, 0xF5, 6), x(.fsub, .abs, 0xED, 7),
    x(.fsub, .ind, 0xF2, 8),    x(.fsub, .ind_y, 0xF1, 8),
    // ── FMUL: A ⟵ A × M ─────────────────────────────────────────────────
    x(.fmul, .imm64, 0x23, 6),  x(.fmul, .near, 0x25, 6),
    x(.fmul, .near_x, 0x35, 6), x(.fmul, .abs, 0x2D, 7),
    x(.fmul, .ind, 0x32, 8),    x(.fmul, .ind_y, 0x31, 8),
    // ── FDIV: A ⟵ A ÷ M ─────────────────────────────────────────────────
    x(.fdiv, .imm64, 0x43, 20), x(.fdiv, .near, 0x45, 20),
    x(.fdiv, .near_x, 0x55, 20), x(.fdiv, .abs, 0x4D, 21),
    x(.fdiv, .ind, 0x52, 22),   x(.fdiv, .ind_y, 0x51, 22),
    // ── FCMP: flags ⟵ A ? M (Z eq, N lt, C ge; unordered sets V only) ───
    x(.fcmp, .imm64, 0xC3, 5),  x(.fcmp, .near, 0xC5, 5),
    x(.fcmp, .near_x, 0xD5, 5), x(.fcmp, .abs, 0xCD, 6),
    x(.fcmp, .ind, 0xD2, 7),    x(.fcmp, .ind_y, 0xD1, 7),
    // ── Unary, on A ──────────────────────────────────────────────────────
    x(.fsqrt, .acc, 0x0A, 20),
    x(.ftoi, .acc, 0x1A, 4), // f64 → i64, truncate toward zero; sat + V
    x(.itof, .acc, 0x3A, 4), // i64 → f64, round-to-nearest-even
    // ── FP32 in memory, FP64 in A: widen on load, narrow on store ───────
    x(.flds, .near, 0xA5, 4),   x(.flds, .near_x, 0xB5, 4),
    x(.flds, .abs, 0xAD, 5),    x(.flds, .ind, 0xB2, 6),
    x(.flds, .ind_y, 0xB1, 6),  x(.fsts, .near, 0x85, 4),
    x(.fsts, .near_x, 0x95, 4), x(.fsts, .abs, 0x8D, 5),
    x(.fsts, .ind, 0x92, 6),    x(.fsts, .ind_y, 0x91, 6),
    // ── Tier 1 vectors: the extended $?7 column, spent whole ────────────
    // Lanewise costs mirror the scalar ops (eight lanes are parallel
    // silicon, not eight passes); loads/stores price the 64-byte move;
    // reductions price the three tree levels.
    x(.vld, .desc, 0x07, 8),    x(.vst, .desc, 0x17, 8),
    x(.vbca, .desc, 0x27, 2),   x(.vfadd, .desc, 0x37, 6),
    x(.vfsub, .desc, 0x47, 6),  x(.vfmul, .desc, 0x57, 6),
    x(.vfdiv, .desc, 0x67, 22), x(.vadd, .desc, 0x77, 3),
    x(.vand, .desc, 0x87, 3),   x(.vora, .desc, 0x97, 3),
    x(.veor, .desc, 0xA7, 3),   x(.vradd, .desc, 0xB7, 8),
    x(.vrmax, .desc, 0xC7, 8),  x(.vrmin, .desc, 0xD7, 8),
    x(.vperm, .desc, 0xE7, 3),
};

/// Near-page base of the 16-slot macro vector table (MACTAB).
pub const mactab_base: u16 = 0xF80;

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
    if (d[ext_prefix] != null)
        @compileError("the extended-page prefix byte must stay free on the base page");
    break :blk d;
};

/// Extended-page decode table (after an `ext_prefix` byte). The prefix's
/// own slot stays null here too — prefixes do not stack.
pub const xdecode: [256]?Encoding = blk: {
    var d: [256]?Encoding = .{null} ** 256;
    for (xtable) |enc| {
        if (enc.page != .ext)
            @compileError("xtable entries must be page .ext");
        if (d[enc.opcode] != null)
            @compileError(std.fmt.comptimePrint(
                "duplicate extended opcode 0x{X:0>2}",
                .{enc.opcode},
            ));
        d[enc.opcode] = enc;
    }
    if (d[ext_prefix] != null)
        @compileError("prefixes do not stack: $42 is undefined on the extended page");
    break :blk d;
};

/// Find the encoding for a (mnemonic, mode) pair; null if that pairing
/// doesn't exist in the ISA. Used by the assembler. Searches both pages —
/// a mnemonic lives on exactly one.
pub fn lookup(mnemonic: Mnemonic, mode: Mode) ?Encoding {
    inline for (table) |enc| {
        if (enc.mnemonic == mnemonic and enc.mode == mode) return enc;
    }
    inline for (xtable) |enc| {
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

test "extended page round-trips and sizes include the prefix" {
    for (xtable) |enc| {
        const got = xdecode[enc.opcode] orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(enc.mnemonic, got.mnemonic);
        try std.testing.expectEqual(enc.mode, got.mode);
    }
    // FADD ##imm: prefix + opcode + 8 = 10 bytes; base-page LDA ##imm stays 9.
    try std.testing.expectEqual(@as(u8, 10), lookup(.fadd, .imm64).?.size());
    try std.testing.expectEqual(@as(u8, 9), lookup(.lda, .imm64).?.size());
    // The prefix's own slot is null on BOTH pages — prefixes do not stack.
    try std.testing.expectEqual(@as(?Encoding, null), decode[ext_prefix]);
    try std.testing.expectEqual(@as(?Encoding, null), xdecode[ext_prefix]);
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
