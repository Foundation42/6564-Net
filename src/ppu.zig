//! PPU — a picture processor for the peripheral row.
//!
//! The northstar (joey-bird, rendered for real) exposed an inefficiency: to
//! put a scene on the glass the core would have to lay down every pixel in
//! software — ~43,000 instructions for a single 64×48 frame, twenty times
//! the entire rest of the game, and worse, that cost warps the frame clock
//! (every cycle the core spends drawing shifts how the pad's input stream
//! interleaves). The platform's answer is the one it already gave arithmetic
//! in §7.6: make it device work. matmul is "the core describes the operands,
//! the accelerator does the reduction"; the PPU is the same move for pixels —
//! the core describes the SCENE (a compact display list), the PPU composites
//! it. The heritage is exact: a 6502 ran the NES beside a Picture Processing
//! Unit that did tiles and sprites so the CPU never touched a pixel.
//!
//! It is an ordinary §7.6 accelerator — matmul's twin. A grant carries one
//! region holding, at caller-named offsets, a SPRITE SHEET (8×8 bitmaps,
//! written once), a DISPLAY LIST (rewritten each frame), and the FRAMEBUFFER
//! (the PPU's output). Acceptance sets OWNED; the completion is the release
//! fence, after which the core peeks the framebuffer for collision (§7.7)
//! and presents it to the display. The work is integer and the reduction
//! order is nil, so the contract is `deterministic` (§7.5): every
//! implementation composites the same bytes.

const std = @import("std");
const dev = @import("dev.zig");

/// Sprites and tiles are 8×8 — the NES cell, the C64 char, the size a 6502
/// era measured art in.
pub const tile = 8;
pub const tile_px = tile * tile;

/// A pixel byte in the framebuffer is a palette index (the display owns the
/// colours). In a SPRITE'S bitmap one value is special: 0xFF means
/// transparent — leave whatever the background put there. Every other value
/// paints. (A RECT or CLEAR writes its colour verbatim; only sprites have
/// holes.)
pub const transparent: u8 = 0xFF;

/// Display-list opcodes. Each command is a fixed 8 bytes so the core can
/// stamp one out with byte stores and the PPU can stride the list without
/// parsing lengths.
pub const Op = enum(u8) {
    end = 0, // [0] — the list is done
    clear = 1, // [1][color] — fill the whole framebuffer
    rect = 2, // [2][x][y][w][h][color] — a filled rectangle (pipes, ground)
    sprite = 3, // [3][id][x][y][flags] — blit sheet[id]; flags bit0 flip-x, bit1 flip-y
    _,
};

pub const flag_flip_x: u8 = 1;
pub const flag_flip_y: u8 = 2;

pub const Ppu = struct {
    /// Frames composited — the headless proof the PPU ran, alongside the
    /// display's own frame count.
    frames: u64 = 0,

    fn handle(self: *Ppu, payload: []const u8) dev.Result {
        _ = self;
        // Contract (u64 LE words, matmul's shape):
        //   w0 reserved tag   w1 region slot   w2 token
        //   w3 fb_off         w4 W | H<<16     w5 dl_off   w6 sheet_off
        if (payload.len < 56) return .{ .status = .reject_no_buffer };
        const fb_off = word(payload, 3);
        const dims = word(payload, 4);
        const w: u64 = @as(u16, @truncate(dims));
        const h: u64 = @as(u16, @truncate(dims >> 16));
        if (w == 0 or h == 0 or w > 256 or h > 256) return .{ .status = .reject_capability };
        const dl_off = word(payload, 5);
        const sheet_off = word(payload, 6);
        // The one bounds check the machine makes: the framebuffer must fit.
        // Reads of the list and sheet are clamped to the region at raster
        // time, so a short list simply draws less — never out of bounds.
        const extent = fb_off + w * h;
        var job = dev.DeviceJob{};
        job.words[0] = fb_off;
        job.words[1] = w;
        job.words[2] = h;
        job.words[3] = dl_off;
        job.words[4] = sheet_off;
        // A rough cost: a clear plus a little per pixel. Virtual cycles, so
        // only the ratio matters — enough that a bigger frame costs more.
        const latency = 200 + (w * h) / 4;
        return .{ .action = .{ .submit = .{
            .slot = @truncate(word(payload, 1)),
            .token = word(payload, 2),
            .latency = latency,
            .extent = extent,
            .job = job,
        } } };
    }

    fn complete(self: *Ppu, region: []u8, job: dev.DeviceJob) bool {
        const fb_off: usize = @intCast(job.words[0]);
        const w: usize = @intCast(job.words[1]);
        const h: usize = @intCast(job.words[2]);
        const dl_off: usize = @intCast(job.words[3]);
        const sheet_off: usize = @intCast(job.words[4]);
        if (fb_off + w * h > region.len) return false; // revoked/shrunk under us
        const fb = region[fb_off..][0 .. w * h];
        rasterize(fb, w, h, region, dl_off, sheet_off);
        self.frames += 1;
        return true;
    }

    /// Walk the display list once, in order, compositing into the
    /// framebuffer. Later commands paint over earlier ones — the list IS the
    /// z-order, sky first, bird last. Every write is clipped to the frame and
    /// every read clipped to the region, so a malformed list draws garbage
    /// but never escapes its buffer.
    fn rasterize(fb: []u8, w: usize, h: usize, region: []const u8, dl_off: usize, sheet_off: usize) void {
        var i = dl_off;
        while (i + 8 <= region.len) : (i += 8) {
            const op: Op = @enumFromInt(region[i]);
            switch (op) {
                .end => break,
                .clear => @memset(fb, region[i + 1]),
                .rect => fillRect(fb, w, h, region[i + 1], region[i + 2], region[i + 3], region[i + 4], region[i + 5]),
                .sprite => blit(fb, w, h, region, sheet_off, region[i + 1], region[i + 2], region[i + 3], region[i + 4]),
                _ => {}, // an unknown opcode is a no-op, not a fault
            }
        }
    }

    fn fillRect(fb: []u8, w: usize, h: usize, x: u8, y: u8, rw: u8, rh: u8, color: u8) void {
        var row: usize = y;
        const y_end = @min(@as(usize, y) + rh, h);
        const x_end = @min(@as(usize, x) + rw, w);
        while (row < y_end) : (row += 1) {
            var col: usize = x;
            while (col < x_end) : (col += 1) fb[row * w + col] = color;
        }
    }

    fn blit(fb: []u8, w: usize, h: usize, region: []const u8, sheet_off: usize, id: u8, x: u8, y: u8, flags: u8) void {
        const base = sheet_off + @as(usize, id) * tile_px;
        if (base + tile_px > region.len) return; // sheet slot out of range
        const sprite = region[base..][0..tile_px];
        for (0..tile) |sy| {
            const fy = @as(usize, y) + sy;
            if (fy >= h) continue;
            for (0..tile) |sx| {
                const fx = @as(usize, x) + sx;
                if (fx >= w) continue;
                const src_x = if (flags & flag_flip_x != 0) tile - 1 - sx else sx;
                const src_y = if (flags & flag_flip_y != 0) tile - 1 - sy else sy;
                const v = sprite[src_y * tile + src_x];
                if (v != transparent) fb[fy * w + fx] = v;
            }
        }
    }

    fn word(p: []const u8, i: usize) u64 {
        return std.mem.readInt(u64, p[i * 8 ..][0..8], .little);
    }

    // ── vtable glue — a device on the row, no line in machine.zig ──
    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) dev.Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    fn vtComplete(ptr: *anyopaque, region: []u8, job: dev.DeviceJob) bool {
        return complete(@ptrCast(@alignCast(ptr)), region, job);
    }
    const vtable = dev.Device.VTable{ .handle = vtHandle, .complete = vtComplete };
    pub fn device(self: *Ppu) dev.Device {
        return .{ .ptr = self, .vt = &vtable };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

// Assemble a tiny region by hand — sheet, list, framebuffer at offsets — run
// the raster, and read the pixels back. No machine, no fabric: the PPU's
// arithmetic in isolation, the way dev.zig tests each device's policy.
test "ppu: clear, rect, and a transparent sprite composite in list order" {
    const W = 8;
    const H = 8;
    const sheet_off = 0;
    const dl_off = 64; // one 8×8 sprite = 64 bytes
    const fb_off = 128;
    var region = [_]u8{0} ** 256;

    // sheet[0]: a 2×2 yellow(3) block in the top-left, rest transparent.
    for (0..tile_px) |k| region[sheet_off + k] = transparent;
    region[sheet_off + 0 * tile + 0] = 3;
    region[sheet_off + 0 * tile + 1] = 3;
    region[sheet_off + 1 * tile + 0] = 3;
    region[sheet_off + 1 * tile + 1] = 3;

    // list: CLEAR 0 ; RECT (2,2, 3,3) colour 1 ; SPRITE 0 at (5,5) ; END
    const list = [_][8]u8{
        .{ @intFromEnum(Op.clear), 0, 0, 0, 0, 0, 0, 0 },
        .{ @intFromEnum(Op.rect), 2, 2, 3, 3, 1, 0, 0 },
        .{ @intFromEnum(Op.sprite), 0, 5, 5, 0, 0, 0, 0 },
        .{ @intFromEnum(Op.end), 0, 0, 0, 0, 0, 0, 0 },
    };
    for (list, 0..) |cmd, ci| {
        @memcpy(region[dl_off + ci * 8 ..][0..8], &cmd);
    }

    var job = dev.DeviceJob{};
    job.words[0] = fb_off;
    job.words[1] = W;
    job.words[2] = H;
    job.words[3] = dl_off;
    job.words[4] = sheet_off;

    var ppu = Ppu{};
    try testing.expect(ppu.complete(&region, job));
    try testing.expectEqual(@as(u64, 1), ppu.frames);

    const fb = region[fb_off..][0 .. W * H];
    // cleared to 0
    try testing.expectEqual(@as(u8, 0), fb[0]);
    // rect [2..5)×[2..5) is colour 1
    try testing.expectEqual(@as(u8, 1), fb[2 * W + 2]);
    try testing.expectEqual(@as(u8, 1), fb[4 * W + 4]);
    try testing.expectEqual(@as(u8, 0), fb[5 * W + 5 - 1]); // just outside the rect, before the sprite row
    // sprite's 2×2 painted at (5,5); its transparent pixels left the clear
    try testing.expectEqual(@as(u8, 3), fb[5 * W + 5]);
    try testing.expectEqual(@as(u8, 3), fb[6 * W + 6]);
    try testing.expectEqual(@as(u8, 0), fb[7 * W + 7]); // transparent corner of the sprite
}

test "ppu: writes clip to the framebuffer, never past it" {
    const W = 8;
    const H = 8;
    var region = [_]u8{0} ** 200;
    const fb_off = 64;
    // RECT that runs off the right/bottom edges; END.
    const list = [_][8]u8{
        .{ @intFromEnum(Op.rect), 6, 6, 10, 10, 2, 0, 0 },
        .{ @intFromEnum(Op.end), 0, 0, 0, 0, 0, 0, 0 },
    };
    for (list, 0..) |cmd, ci| @memcpy(region[0 + ci * 8 ..][0..8], &cmd);

    var job = dev.DeviceJob{};
    job.words[0] = fb_off;
    job.words[1] = W;
    job.words[2] = H;
    job.words[3] = 0;
    job.words[4] = 128;

    var ppu = Ppu{};
    try testing.expect(ppu.complete(&region, job));
    const fb = region[fb_off..][0 .. W * H];
    try testing.expectEqual(@as(u8, 2), fb[7 * W + 7]); // corner drawn
    // the bytes after the framebuffer are untouched
    try testing.expectEqual(@as(u8, 0), region[fb_off + W * H]);
}
