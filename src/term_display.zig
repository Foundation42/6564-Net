//! TermDisplay — a real display that scans the framebuffer to your terminal.
//!
//! It lives OUTSIDE dev.zig on purpose. The peripheral row's contract is a
//! vtable (§7.5, dev.zig), and the whole claim of that refactor was that a
//! new device joins the row by supplying its own vtable — no change to the
//! machine, no new arm in any switch, not even a line in dev.zig. This file
//! is the proof: an external device, in its own module, that the loader
//! attaches at $FF07 instead of the headless Display. Same `Present`
//! submission, same $6772 completion fence, same frame-clock backpressure —
//! only the completion differs: where the headless display checksums the
//! frame, this one paints it, as truecolor half-blocks, into the terminal
//! the machine's teletype console has always spoken to. Silicon is an
//! optimization; here the optimization is a human's eyes.
//!
//! Determinism is untouched. The display is an OUTPUT — nothing it does
//! feeds back into the simulation — so painting real pixels and pacing to
//! the wall clock (so a person can watch) changes not one bit of the run.
//! The frame the glass receives is the frame the actor drew, exactly as the
//! headless Display's checksum has always attested.

const std = @import("std");
const dev = @import("dev.zig");

/// The four-colour playfield palette joey draws into — a pixel byte is an
/// index, and the display owns the colours, as real display hardware owns
/// its DAC. 0 sky, 1 pipe, 2 ground, 3 bird.
const Rgb = struct { r: u8, g: u8, b: u8 };
const palette = [_]Rgb{
    .{ .r = 0x8e, .g = 0xd6, .b = 0xff }, // 0 sky — soft daylight blue
    .{ .r = 0x3a, .g = 0xa0, .b = 0x4a }, // 1 pipe — flappy green
    .{ .r = 0xd8, .g = 0xc0, .b = 0x88 }, // 2 ground — sandy tan
    .{ .r = 0xff, .g = 0xd8, .b = 0x2a }, // 3 bird — the yolk herself
};

pub const TermDisplay = struct {
    /// The vblank interval — the frame clock, exactly as the headless
    /// Display's `period`. Backpressure still paces the sim; `frame_ms`
    /// paces the *human* on top of it.
    period: u64,
    /// Framebuffer width in pixels; height falls out as region.len / width.
    width: u16,
    /// Wall-clock milliseconds to hold each painted frame — output pacing
    /// only, never simulation time.
    frame_ms: u32 = 50,
    frames: u64 = 0,
    checksum: u64 = 0,
    cleared: bool = false,

    fn handle(self: *TermDisplay, payload: []const u8) dev.Result {
        // Present {w0 reserved tag, w1 region slot, w2 token} — the same
        // submission the headless Display makes; the whole region is the
        // frame, no dimensions, because a display shows, it does not compute.
        if (payload.len < 24) return .{ .status = .reject_no_buffer };
        return .{ .action = .{ .submit = .{
            .slot = @truncate(word(payload, 1)),
            .token = word(payload, 2),
            .latency = self.period,
            .extent = 0, // presents whatever length the region is
        } } };
    }

    fn complete(self: *TermDisplay, region: []u8, _: dev.DeviceJob) bool {
        self.frames += 1;
        // The same checksum the headless Display keeps, so a watched run and
        // a headless one agree on what reached the glass, bit for bit.
        var sum: u64 = 0;
        var off: usize = 0;
        while (off + 8 <= region.len) : (off += 8)
            sum +%= std.mem.readInt(u64, region[off..][0..8], .little);
        self.checksum = sum;
        self.paint(region);
        return true;
    }

    fn paint(self: *TermDisplay, region: []const u8) void {
        const w: usize = self.width;
        if (w == 0 or region.len < w) return;
        const h: usize = region.len / w;
        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        const out = bw.writer();
        if (!self.cleared) {
            out.writeAll("\x1b[2J\x1b[?25l") catch {}; // clear once, hide the cursor
            self.cleared = true;
        }
        out.writeAll("\x1b[H") catch {}; // home the cursor; overwrite in place, no flicker
        // Each character cell is two vertical pixels: ▀ (upper half-block)
        // painted with the top pixel's colour as foreground and the bottom
        // pixel's as background. So a WxH frame becomes W columns by H/2 rows,
        // and the terminal shows square-ish pixels.
        var y: usize = 0;
        while (y + 1 < h) : (y += 2) {
            const top = region[y * w ..][0..w];
            const bot = region[(y + 1) * w ..][0..w];
            for (0..w) |x| {
                const t = palette[@min(top[x], 3)];
                const b = palette[@min(bot[x], 3)];
                out.print("\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m\u{2580}", .{
                    t.r, t.g, t.b, b.r, b.g, b.b,
                }) catch return;
            }
            out.writeAll("\x1b[0m\n") catch {};
        }
        bw.flush() catch {};
        // Hold the frame so a human can see it — the frame clock, slowed to
        // human time. Sim determinism is elsewhere and untouched.
        std.time.sleep(@as(u64, self.frame_ms) * std.time.ns_per_ms);
    }

    fn word(p: []const u8, i: usize) u64 {
        return std.mem.readInt(u64, p[i * 8 ..][0..8], .little);
    }

    // ── The vtable glue: this, and a coordinate, is all it takes to be a
    //    device on the row. Nothing in machine.zig or dev.zig knows this
    //    type exists. ──
    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) dev.Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    fn vtComplete(ptr: *anyopaque, region: []u8, job: dev.DeviceJob) bool {
        return complete(@ptrCast(@alignCast(ptr)), region, job);
    }
    fn vtDeinit(ptr: *anyopaque) void {
        _ = ptr;
        // Give the cursor back when the machine tears the device down.
        std.io.getStdOut().writeAll("\x1b[?25h\x1b[0m\n") catch {};
    }
    const vtable = dev.Device.VTable{ .handle = vtHandle, .complete = vtComplete, .deinit = vtDeinit };
    pub fn device(self: *TermDisplay) dev.Device {
        return .{ .ptr = self, .vt = &vtable };
    }
};
