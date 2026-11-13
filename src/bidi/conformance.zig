//! Unicode conformance suites for bidi.zig: BidiCharacterTest.txt and BidiTest.txt (pinned version,
//! fetched by test/fetch-ucd.sh into test/ucd/, which `zig build test` runs first).
//! Both files assume the whole input is one paragraph on one line, as bidi.resolve does.
const std = @import("std");
const bidi = @import("bidi.zig");
const testing = std.testing;

/// "x" in the data files: the character is removed by X9 and has no level.
const x: u8 = 0xff;
const max_len = 512;
const max_print = 8;

const Case = struct {
    cps: []const u21,
    dir: bidi.Direction,
    want_para: ?u8,
    want_levels: []const u8,
    want_order: []const usize,
};

fn printList(comptime T: type, items: []const T) void {
    for (items) |v| {
        if (T == u8 and v == x) std.debug.print(" x", .{}) else std.debug.print(" {d}", .{v});
    }
}

/// True when the case passes. Prints the first few failures in detail.
fn runCase(fba: *std.heap.FixedBufferAllocator, c: Case, label: []const u8, line_no: usize, printed: *usize) bool {
    fba.reset();
    var levels_buf: [max_len]u8 = undefined;
    const levels = levels_buf[0..c.cps.len];
    var ok = c.want_levels.len == c.cps.len;
    const para = bidi.resolve(fba.allocator(), c.cps, c.dir, levels) catch 0xff;
    if (c.want_para) |wp| ok = ok and wp == para;
    if (ok) {
        for (c.want_levels, levels, c.cps) |w, g, cp| {
            const removed = bidi.isRemoved(bidi.classOf(cp));
            ok = ok and (if (w == x) removed else !removed and w == g);
        }
    }
    var order_buf: [max_len]usize = undefined;
    const order = order_buf[0..c.cps.len];
    bidi.reorder(levels, order);
    var vis_buf: [max_len]usize = undefined;
    var n: usize = 0;
    for (order) |idx| {
        if (bidi.isRemoved(bidi.classOf(c.cps[idx]))) continue;
        vis_buf[n] = idx;
        n += 1;
    }
    ok = ok and std.mem.eql(usize, vis_buf[0..n], c.want_order);
    if (!ok and printed.* < max_print) {
        printed.* += 1;
        std.debug.print("\n{s} line {d} dir={s} cps:", .{ label, line_no, @tagName(c.dir) });
        for (c.cps) |cp| std.debug.print(" {X:0>4}", .{cp});
        std.debug.print("\n  want para={?d} levels:", .{c.want_para});
        printList(u8, c.want_levels);
        std.debug.print("\n  got  para={d} levels:", .{para});
        printList(u8, levels);
        std.debug.print("\n  want order:", .{});
        printList(usize, c.want_order);
        std.debug.print("\n  got  order:", .{});
        printList(usize, vis_buf[0..n]);
        std.debug.print("\n", .{});
    }
    return ok;
}

fn readData(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(32 << 20)) catch |e| {
        std.debug.print("cannot read {s} ({s}); run test/fetch-ucd.sh\n", .{ path, @errorName(e) });
        return e;
    };
}

fn parseLevels(out: []u8, s: []const u8) !usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |t| : (n += 1) out[n] = if (t[0] == 'x') x else try std.fmt.parseInt(u8, t, 10);
    return n;
}

fn parseOrder(out: []usize, s: []const u8) !usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |t| : (n += 1) out[n] = try std.fmt.parseInt(usize, t, 10);
    return n;
}

test "BidiCharacterTest.txt" {
    const gpa = testing.allocator;
    const data = try readData(gpa, "test/ucd/BidiCharacterTest.txt");
    defer gpa.free(data);
    var arena_buf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    var cps_buf: [max_len]u21 = undefined;
    var lev_buf: [max_len]u8 = undefined;
    var ord_buf: [max_len]usize = undefined;
    var cases: usize = 0;
    var failed: usize = 0;
    var printed: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, ';');
        const cps_s = f.next().?;
        const dir_s = f.next().?;
        const para_s = f.next().?;
        const lev_s = f.next().?;
        const ord_s = f.next().?;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, cps_s, " \t");
        while (it.next()) |t| : (n += 1) cps_buf[n] = try std.fmt.parseInt(u21, t, 16);
        const nl = try parseLevels(&lev_buf, lev_s);
        const no = try parseOrder(&ord_buf, ord_s);
        const dir: bidi.Direction = switch (dir_s[0]) {
            '0' => .ltr,
            '1' => .rtl,
            else => .auto,
        };
        cases += 1;
        if (!runCase(&fba, .{
            .cps = cps_buf[0..n],
            .dir = dir,
            .want_para = try std.fmt.parseInt(u8, para_s, 10),
            .want_levels = lev_buf[0..nl],
            .want_order = ord_buf[0..no],
        }, "BidiCharacterTest", line_no, &printed)) failed += 1;
    }
    std.debug.print("BidiCharacterTest: {d} cases, {d} failed\n", .{ cases, failed });
    try testing.expect(cases > 50_000);
    try testing.expectEqual(@as(usize, 0), failed);
}

/// One code point standing for each bidi class in BidiTest.txt. ON is not a bracket.
fn representative(c: bidi.Class) u21 {
    return switch (c) {
        .L => 0x0061,
        .R => 0x05D0,
        .AL => 0x0627,
        .EN => 0x0030,
        .ES => 0x002B,
        .ET => 0x0023,
        .AN => 0x0660,
        .CS => 0x002C,
        .NSM => 0x0300,
        .BN => 0x00AD,
        .B => 0x2029,
        .S => 0x0009,
        .WS => 0x0020,
        .ON => 0x0021,
        .LRE => 0x202A,
        .LRO => 0x202D,
        .RLE => 0x202B,
        .RLO => 0x202E,
        .PDF => 0x202C,
        .LRI => 0x2066,
        .RLI => 0x2067,
        .FSI => 0x2068,
        .PDI => 0x2069,
    };
}

test "BidiTest.txt representatives have their class" {
    inline for (@typeInfo(bidi.Class).@"enum".field_values) |v| {
        const c: bidi.Class = @enumFromInt(v);
        try testing.expectEqual(c, bidi.classOf(representative(c)));
    }
}

test "BidiTest.txt" {
    const gpa = testing.allocator;
    const data = try readData(gpa, "test/ucd/BidiTest.txt");
    defer gpa.free(data);
    var arena_buf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    var cps_buf: [max_len]u21 = undefined;
    var lev_buf: [max_len]u8 = undefined;
    var ord_buf: [max_len]usize = undefined;
    var nl: usize = 0;
    var no: usize = 0;
    var cases: usize = 0;
    var failed: usize = 0;
    var printed: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "@Levels:")) {
            nl = try parseLevels(&lev_buf, line["@Levels:".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "@Reorder:")) {
            no = try parseOrder(&ord_buf, line["@Reorder:".len..]);
            continue;
        }
        if (line[0] == '@') continue;
        var f = std.mem.splitScalar(u8, line, ';');
        const classes_s = f.next().?;
        const bits = try std.fmt.parseInt(u8, std.mem.trim(u8, f.next().?, " \t"), 16);
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, classes_s, " \t");
        while (it.next()) |t| : (n += 1) cps_buf[n] = representative(std.meta.stringToEnum(bidi.Class, t).?);
        // bit 0: auto, bit 1: LTR, bit 2: RTL
        for ([_]struct { u8, bidi.Direction }{ .{ 1, .auto }, .{ 2, .ltr }, .{ 4, .rtl } }) |d| {
            if (bits & d[0] == 0) continue;
            cases += 1;
            if (!runCase(&fba, .{
                .cps = cps_buf[0..n],
                .dir = d[1],
                .want_para = null,
                .want_levels = lev_buf[0..nl],
                .want_order = ord_buf[0..no],
            }, "BidiTest", line_no, &printed)) failed += 1;
        }
    }
    std.debug.print("BidiTest: {d} cases, {d} failed\n", .{ cases, failed });
    try testing.expect(cases > 400_000);
    try testing.expectEqual(@as(usize, 0), failed);
}
