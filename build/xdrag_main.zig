//! A minimal X11 pointer driver, for the sidebar cells: XTEST motion, buttons
//! and key chords.
//!
//! Why not an FFI from the harness: Xlib client calls from a second process
//! linked that way crashed inside XQueryExtension on this host (probed
//! 2026-11-05). A small program that opens the display once and keeps it for
//! the whole gesture is how Xlib is meant to be used.
//!
//! Usage:
//!   njuggle-xdrag <display> <x1> <y1> <x2> <y2>   press, drag, release
//!   njuggle-xdrag <display> motion <x> <y>        pointer motion, no buttons
//!   njuggle-xdrag <display> key <keysym>...       a key chord
//!
//! Licence: AGPLv3 (njuggle).

const std = @import("std");

extern fn XOpenDisplay(name: [*:0]const u8) ?*XDisplay;
extern fn XFlush(d: *XDisplay) c_int;
extern fn XCloseDisplay(d: *XDisplay) c_int;
extern fn XSync(d: *XDisplay, discard: c_int) c_int;
extern fn XTestFakeMotionEvent(d: *XDisplay, screen: c_int, x: c_int, y: c_int, delay: c_ulong) c_int;
extern fn XStringToKeysym(name: [*:0]const u8) c_ulong;
extern fn XKeysymToKeycode(d: *XDisplay, keysym: c_ulong) u8;
extern fn XTestFakeKeyEvent(d: *XDisplay, keycode: c_uint, press: c_int, delay: c_ulong) c_int;
extern fn XTestFakeButtonEvent(d: *XDisplay, button: c_uint, press: c_int, delay: c_ulong) c_int;

pub const XDisplay = opaque {};

fn move(d: *XDisplay, x: f64, y: f64) void {
    _ = XTestFakeMotionEvent(d, -1, @intFromFloat(@floor(x)), @intFromFloat(@floor(y)), 0);
    _ = XFlush(d);
}

fn settle(d: *XDisplay, ms: u64) void {
    _ = XSync(d, 0);
    // A blocking wait with no other work to overlap: the OS call directly.
    const ts = CPosixTimespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = c_nanosleep(&ts, null);
}

const CPosixTimespec = extern struct {
    sec: isize,
    nsec: isize,
};

extern fn nanosleep(req: *const CPosixTimespec, rem: ?*CPosixTimespec) c_int;
const c_nanosleep = nanosleep;

pub fn main(init: std.process.Init) !u8 {
    var args_buf: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| {
        if (n < args_buf.len) {
            args_buf[n] = arg;
            n += 1;
        }
    }
    if (n < 3) {
        std.debug.print("usage: njuggle-xdrag <display> x1 y1 x2 y2 | <display> motion x y | <display> key <keysym>...\n", .{});
        return 2;
    }

    var disp_buf: [64]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const disp = try std.fmt.bufPrintSentinel(&disp_buf, "{s}", .{args_buf[1]}, 0);
    const d = XOpenDisplay(disp.ptr) orelse {
        std.debug.print("cannot open display {s}\n", .{args_buf[1]});
        return 1;
    };
    defer _ = XCloseDisplay(d);

    // `key <keysym>...`: a chord, each keysym pressed in order and released in
    // reverse.
    if (std.mem.eql(u8, args_buf[2], "key")) {
        var down: usize = 0;
        for (args_buf[3..n]) |name| {
            const sym = XStringToKeysym(try std.fmt.bufPrintSentinel(&name_buf, "{s}", .{name}, 0));
            const code = XKeysymToKeycode(d, sym);
            if (code == 0) {
                std.debug.print("no keycode for {s}\n", .{name});
                return 1;
            }
            _ = XTestFakeKeyEvent(d, code, 1, 0);
            _ = XFlush(d);
            settle(d, 30);
            down += 1;
        }
        settle(d, 50);
        var i: usize = 0;
        while (i < down) : (i += 1) {
            const name = args_buf[3 + down - 1 - i];
            const sym = XStringToKeysym(try std.fmt.bufPrintSentinel(&name_buf, "{s}", .{name}, 0));
            _ = XTestFakeKeyEvent(d, XKeysymToKeycode(d, sym), 0, 0);
            _ = XFlush(d);
        }
        settle(d, 150);
        const out0 = std.Io.File.stdout();
        out0.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "key done\n") catch {};
        return 0;
    }

    // `motion <x> <y> [<x> <y>...]`: pointer motion with NO buttons. A motion
    // sent after a release must not move a latched drag.
    if (std.mem.eql(u8, args_buf[2], "motion")) {
        var i: usize = 3;
        while (i + 1 < n) : (i += 2) {
            move(d, try std.fmt.parseFloat(f64, args_buf[i]), try std.fmt.parseFloat(f64, args_buf[i + 1]));
            settle(d, 60);
        }
        const outm = std.Io.File.stdout();
        outm.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "move done\n") catch {};
        return 0;
    }

    if (n < 6) {
        std.debug.print("usage: njuggle-xdrag <display> x1 y1 x2 y2\n", .{});
        return 2;
    }
    const x1 = try std.fmt.parseFloat(f64, args_buf[2]);
    const y1 = try std.fmt.parseFloat(f64, args_buf[3]);
    const x2 = try std.fmt.parseFloat(f64, args_buf[4]);
    const y2 = try std.fmt.parseFloat(f64, args_buf[5]);

    move(d, x1, y1);
    settle(d, 200);
    _ = XTestFakeButtonEvent(d, 1, 1, 0);
    settle(d, 250);
    // The first motion after the press is emitted by GTK as the drag BEGIN; a
    // step in the same frame as the press can be absorbed (probed 2026-11-05:
    // begin then end, no update). One slow step, held, then the rest.
    move(d, x1 + (x2 - x1) * 0.15, y1 + (y2 - y1) * 0.15);
    settle(d, 300);
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        const t: f64 = @as(f64, @floatFromInt(i)) / 10.0;
        move(d, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
        settle(d, 40);
    }
    _ = XTestFakeButtonEvent(d, 1, 0, 0);
    settle(d, 300);

    const out = std.Io.File.stdout();
    out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "drag done\n") catch {};
    return 0;
}
