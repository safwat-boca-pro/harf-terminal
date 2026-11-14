//! Which grid rows need Arabic layout, and which base direction they get (brief 3.3, 4.4).
//! Pure functions over a row's codepoints; no fonts, no grid.
const std = @import("std");
const bidi = @import("bidi/bidi.zig");

pub const Policy = enum { auto, ltr, rtl };
pub const Facts = struct { needs_layout: bool, rtl_base: bool };

fn isRtlClass(c: bidi.Class) bool {
    return switch (c) {
        .R, .AL, .RLE, .RLO, .RLI, .FSI => true,
        else => false,
    };
}

fn isBoxOrBlock(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x259F;
}

/// `cps` is the row in logical order, blank cells as ' '.
/// A row needs layout if it holds R, AL or an explicit RTL control. For `auto`, the base is RTL
/// only if the first non-blank cell is itself strong RTL and the row has no box or block
/// character: stricter than UAX #9 P2 so a prompt such as "➜  ~ الحمد" is not flipped.
pub fn analyze(cps: []const u21, policy: Policy) Facts {
    var needs = false;
    var box = false;
    for (cps) |cp| {
        if (isRtlClass(bidi.classOf(cp))) needs = true;
        if (isBoxOrBlock(cp)) box = true;
    }
    const rtl = switch (policy) {
        .rtl => true,
        .ltr => false,
        .auto => blk: {
            if (!needs or box) break :blk false;
            for (cps) |cp| {
                if (cp == ' ') continue;
                const c = bidi.classOf(cp);
                break :blk c == .R or c == .AL;
            }
            break :blk false;
        },
    };
    return .{ .needs_layout = needs, .rtl_base = rtl };
}

fn facts(str: []const u8, policy: Policy) !Facts {
    var buf: [256]u21 = undefined;
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(str)).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) buf[n] = cp;
    return analyze(buf[0..n], policy);
}

test "needs layout" {
    try std.testing.expect(!(try facts("hello world", .auto)).needs_layout);
    try std.testing.expect((try facts("مرحبا world 123", .auto)).needs_layout);
    try std.testing.expect(!(try facts("١٢٣", .auto)).needs_layout); // Arabic-Indic digits are AN, not strong
    try std.testing.expect((try facts("ls ملف.txt", .auto)).needs_layout);
    try std.testing.expect((try facts("a\u{202B}b", .auto)).needs_layout); // RLE
    try std.testing.expect(!(try facts("", .auto)).needs_layout);
}

test "base auto" {
    try std.testing.expect((try facts("مرحبا world 123", .auto)).rtl_base);
    try std.testing.expect((try facts("السلام عليكم.", .auto)).rtl_base);
    try std.testing.expect(!(try facts("world مرحبا", .auto)).rtl_base);
    try std.testing.expect(!(try facts("ls ملف.txt", .auto)).rtl_base);
    try std.testing.expect(!(try facts("➜  ~ الحمد لله", .auto)).rtl_base); // a prompt must not flip
    try std.testing.expect(!(try facts("❯ مرحبا", .auto)).rtl_base);
    try std.testing.expect((try facts("  مرحبا", .auto)).rtl_base); // leading blanks are skipped
    try std.testing.expect(!(try facts("١٢٣ مرحبا", .auto)).rtl_base); // first non-blank is AN
}

test "box row is ltr" {
    const auto = try facts("│ مرحبا    │", .auto);
    try std.testing.expect(auto.needs_layout and !auto.rtl_base);
    try std.testing.expect((try facts("│ مرحبا    │", .rtl)).rtl_base); // an override wins
}

test "overrides" {
    const f = try facts("hello", .rtl);
    try std.testing.expect(f.rtl_base and !f.needs_layout);
    try std.testing.expect(!(try facts("مرحبا", .ltr)).rtl_base);
}
