//! UAX #9, the Unicode Bidirectional Algorithm (Unicode 18.0.0 data, see tables.zig).
//!
//! Input is one paragraph of code points in logical order, treated as a single line (a terminal
//! row). Output is an embedding level per code point, then a visual order from those levels.
//! No libc, no platform calls. The conformance suites run from conformance.zig.
const std = @import("std");
const tables = @import("tables.zig");

pub const Class = enum(u8) {
    L, R, AL, EN, ES, ET, AN, CS, NSM, BN, B, S, WS, ON, LRE, LRO, RLE, RLO, PDF, LRI, RLI, FSI, PDI,
};

pub const ClassRange = struct { lo: u21, hi: u21, class: Class };
pub const Bracket = struct { cp: u21, pair: u21, open: bool };

/// Base (paragraph) direction: fixed, or chosen from the first strong character (rules P2, P3).
pub const Direction = enum { ltr, rtl, auto };

fn rangeOrder(cp: u21, r: ClassRange) std.math.Order {
    if (cp < r.lo) return .lt;
    if (cp > r.hi) return .gt;
    return .eq;
}

/// Bidi_Class: explicit entry, else the default of its block (unassigned code points in
/// right-to-left and currency blocks), else L.
pub fn classOf(cp: u21) Class {
    if (std.sort.binarySearch(ClassRange, &tables.classes, cp, rangeOrder)) |i| return tables.classes[i].class;
    if (std.sort.binarySearch(ClassRange, &tables.defaults, cp, rangeOrder)) |i| return tables.defaults[i].class;
    return .L;
}

fn bracketOrder(cp: u21, b: Bracket) std.math.Order {
    return std.math.order(cp, b.cp);
}

fn bracketOf(cp: u21) ?Bracket {
    const i = std.sort.binarySearch(Bracket, &tables.brackets, cp, bracketOrder) orelse return null;
    return tables.brackets[i];
}

/// BD16 compares brackets by canonical equivalence; the only canonical pairs among them are these.
// ponytail: hardcoded for Unicode 18.0.0. Re-check against BidiBrackets/UnicodeData decompositions on every Unicode bump.
fn canonBracket(cp: u21) u21 {
    return switch (cp) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => cp,
    };
}

/// Characters of these classes are removed by rule X9: they take no part in the algorithm and
/// have no position of their own in the visual order.
pub fn isRemoved(c: Class) bool {
    return switch (c) {
        .LRE, .RLE, .LRO, .RLO, .PDF, .BN => true,
        else => false,
    };
}

fn isIsolateInitiator(c: Class) bool {
    return c == .LRI or c == .RLI or c == .FSI;
}

/// Rule L1 treats these like whitespace: they take the paragraph level before a separator or line end.
fn isLineEndSpace(c: Class) bool {
    return switch (c) {
        .WS, .LRI, .RLI, .FSI, .PDI, .LRE, .RLE, .LRO, .RLO, .PDF, .BN => true,
        else => false,
    };
}

fn isNeutralOrIsolate(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .FSI, .LRI, .RLI, .PDI => true,
        else => false,
    };
}

/// Direction a type counts as in N0-N2: EN and AN count as R. Null for neutrals.
fn strongDir(c: Class) ?Class {
    return switch (c) {
        .L => .L,
        .R, .EN, .AN => .R,
        else => null,
    };
}

fn dirOfLevel(level: u8) Class {
    return if (level & 1 == 1) .R else .L;
}

/// Rules P2 and P3 on orig[start..end]: the level (0 or 1) of the first strong character,
/// skipping isolates, or null if there is none.
fn firstStrong(orig: []const Class, match_pdi: []const usize, start: usize, end: usize) ?u8 {
    var i = start;
    while (i < end) : (i += 1) {
        switch (orig[i]) {
            .L => return 0,
            .R, .AL => return 1,
            .LRI, .RLI, .FSI => {
                if (match_pdi[i] == orig.len) return null; // unmatched: skips to the paragraph end
                i = match_pdi[i];
            },
            else => {},
        }
    }
    return null;
}

const max_depth = 125;

const Entry = struct { level: u8, override: ?Class, isolate: bool };

/// Resolves embedding levels (rules P2-I2, then L1 with the whole text as one line).
/// `levels.len` must equal `cps.len`. Returns the paragraph level. A character removed by X9
/// gets the level of the character before it (the paragraph level at the start).
pub fn resolve(gpa: std.mem.Allocator, cps: []const u21, dir: Direction, levels: []u8) std.mem.Allocator.Error!u8 {
    const n = cps.len;
    std.debug.assert(levels.len == n);
    if (n == 0) return if (dir == .rtl) 1 else 0;

    // Scratch: usize arrays carved from one slab, plus classes and explicit levels.
    const slab = try gpa.alloc(usize, 8 * n + 1);
    defer gpa.free(slab);
    const classes = try gpa.alloc(Class, 2 * n);
    defer gpa.free(classes);
    const lvl0 = try gpa.alloc(u8, n);
    defer gpa.free(lvl0);
    const match_pdi = slab[0..n]; // isolate initiator -> its PDI, or n
    const match_init = slab[n .. 2 * n]; // PDI -> its initiator, or n
    const nr = slab[2 * n .. 3 * n]; // indices of characters not removed by X9
    const run_start = slab[3 * n .. 4 * n + 1]; // level runs, as positions in nr
    const run_of = slab[4 * n + 1 .. 5 * n + 1]; // character index -> its level run
    const seq = slab[5 * n + 1 .. 6 * n + 1];
    const closer_of = slab[6 * n + 1 .. 7 * n + 1];
    const open_stack = slab[7 * n + 1 .. 8 * n + 1];
    const orig = classes[0..n];
    const types = classes[n .. 2 * n];
    for (cps, orig, types) |cp, *o, *t| {
        o.* = classOf(cp);
        t.* = o.*;
    }

    // BD9: match isolate initiators with PDIs.
    @memset(match_pdi, n);
    @memset(match_init, n);
    var depth: usize = 0;
    for (orig, 0..) |c, i| {
        if (isIsolateInitiator(c)) {
            open_stack[depth] = i;
            depth += 1;
        } else if (c == .PDI and depth > 0) {
            depth -= 1;
            match_pdi[open_stack[depth]] = i;
            match_init[i] = open_stack[depth];
        }
    }

    // P2, P3.
    const para: u8 = switch (dir) {
        .ltr => 0,
        .rtl => 1,
        .auto => firstStrong(orig, match_pdi, 0, n) orelse 0,
    };

    // X1-X8: explicit levels, directional status stack.
    var stack: [max_depth + 2]Entry = undefined;
    stack[0] = .{ .level = para, .override = null, .isolate = false };
    var sp: usize = 1;
    var overflow_isolate: usize = 0;
    var overflow_embedding: usize = 0;
    var valid_isolate: usize = 0;
    for (orig, 0..) |c, i| {
        switch (c) {
            .RLE, .LRE, .RLO, .LRO => {
                lvl0[i] = stack[sp - 1].level;
                const rtl = c == .RLE or c == .RLO;
                const next = nextLevel(stack[sp - 1].level, rtl);
                if (next <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    const ov: ?Class = switch (c) {
                        .RLO => .R,
                        .LRO => .L,
                        else => null,
                    };
                    stack[sp] = .{ .level = next, .override = ov, .isolate = false };
                    sp += 1;
                } else if (overflow_isolate == 0) {
                    overflow_embedding += 1;
                }
            },
            .RLI, .LRI, .FSI => {
                lvl0[i] = stack[sp - 1].level;
                if (stack[sp - 1].override) |o| types[i] = o;
                const rtl = switch (c) {
                    .RLI => true,
                    .LRI => false,
                    else => blk: {
                        const end = if (match_pdi[i] == n) n else match_pdi[i];
                        break :blk (firstStrong(orig, match_pdi, i + 1, end) orelse 0) == 1;
                    },
                };
                const next = nextLevel(stack[sp - 1].level, rtl);
                if (next <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    valid_isolate += 1;
                    stack[sp] = .{ .level = next, .override = null, .isolate = true };
                    sp += 1;
                } else {
                    overflow_isolate += 1;
                }
            },
            .PDI => {
                if (overflow_isolate > 0) {
                    overflow_isolate -= 1;
                } else if (valid_isolate > 0) {
                    overflow_embedding = 0;
                    while (!stack[sp - 1].isolate) sp -= 1;
                    sp -= 1;
                    valid_isolate -= 1;
                }
                lvl0[i] = stack[sp - 1].level;
                if (stack[sp - 1].override) |o| types[i] = o;
            },
            .PDF => {
                lvl0[i] = stack[sp - 1].level;
                if (overflow_isolate > 0) {
                    // nothing
                } else if (overflow_embedding > 0) {
                    overflow_embedding -= 1;
                } else if (!stack[sp - 1].isolate and sp >= 2) {
                    sp -= 1;
                }
            },
            .B => { // X8: a paragraph separator ends everything
                lvl0[i] = para;
                sp = 1;
                overflow_isolate = 0;
                overflow_embedding = 0;
                valid_isolate = 0;
            },
            .BN => lvl0[i] = stack[sp - 1].level,
            else => {
                lvl0[i] = stack[sp - 1].level;
                if (stack[sp - 1].override) |o| types[i] = o;
            },
        }
    }
    @memcpy(levels, lvl0);

    // X9, X10: level runs over the surviving characters, then isolating run sequences.
    var nr_len: usize = 0;
    for (orig, 0..) |c, i| {
        if (isRemoved(c)) continue;
        nr[nr_len] = i;
        nr_len += 1;
    }
    var runs: usize = 0;
    for (0..nr_len) |k| {
        if (k == 0 or lvl0[nr[k]] != lvl0[nr[k - 1]]) {
            run_start[runs] = k;
            runs += 1;
        }
    }
    run_start[runs] = nr_len;
    for (0..runs) |r| {
        for (nr[run_start[r]..run_start[r + 1]]) |i| run_of[i] = r;
    }
    const cx = Ctx{ .cps = cps, .orig = orig, .types = types, .levels = levels, .closer_of = closer_of };
    for (0..runs) |r| {
        const first = nr[run_start[r]];
        if (orig[first] == .PDI and match_init[first] != n) continue; // continues an earlier sequence
        var len: usize = 0;
        var cur = r;
        while (true) {
            for (nr[run_start[cur]..run_start[cur + 1]]) |i| {
                seq[len] = i;
                len += 1;
            }
            const last = seq[len - 1];
            if (isIsolateInitiator(orig[last]) and match_pdi[last] != n) {
                cur = run_of[match_pdi[last]];
            } else break;
        }
        const level = lvl0[seq[0]];
        // sos: the level before the sequence; eos: the level after it (paragraph level after an unmatched initiator).
        var before: usize = seq[0];
        while (before > 0 and isRemoved(orig[before - 1])) before -= 1;
        const prev_level = if (before > 0) lvl0[before - 1] else para;
        var after: usize = seq[len - 1] + 1;
        while (after < n and isRemoved(orig[after])) after += 1;
        const next_level = if (isIsolateInitiator(orig[seq[len - 1]]) or after >= n) para else lvl0[after];
        resolveSequence(cx, seq[0..len], level, dirOfLevel(@max(prev_level, level)), dirOfLevel(@max(next_level, level)));
    }

    // Removed characters take the level of the one before them.
    var prev_level = para;
    for (orig, levels) |c, *l| {
        if (isRemoved(c)) l.* = prev_level else prev_level = l.*;
    }

    // L1: separators, and whitespace before them or at the line end, go to the paragraph level.
    var i: usize = n;
    var trailing = true;
    while (i > 0) {
        i -= 1;
        const c = orig[i];
        if (c == .B or c == .S) {
            levels[i] = para;
            trailing = true;
        } else if (trailing and isLineEndSpace(c)) {
            levels[i] = para;
        } else trailing = false;
    }
    return para;
}

fn nextLevel(level: u8, rtl: bool) u8 {
    return if (rtl) (level + 1) | 1 else (level + 2) & ~@as(u8, 1);
}

const Ctx = struct {
    cps: []const u21,
    orig: []const Class,
    types: []Class,
    levels: []u8,
    closer_of: []usize,
};

/// Rules W1-W7, N0-N2, I1-I2 on one isolating run sequence (indices `seq`, all at `level`).
fn resolveSequence(cx: Ctx, seq: []const usize, level: u8, sos: Class, eos: Class) void {
    const types = cx.types;
    const len = seq.len;
    const e = dirOfLevel(level);

    // W1: NSM takes the type of the character before it (ON after an isolate initiator or PDI).
    var prev: Class = sos;
    for (seq) |i| {
        if (types[i] == .NSM) types[i] = switch (prev) {
            .LRI, .RLI, .FSI, .PDI => .ON,
            else => prev,
        };
        prev = types[i];
    }
    // W2: EN after AL becomes AN. W3: AL becomes R.
    var last_strong: Class = sos;
    for (seq) |i| switch (types[i]) {
        .L, .R => last_strong = types[i],
        .AL => {
            last_strong = .AL;
            types[i] = .R;
        },
        .EN => if (last_strong == .AL) {
            types[i] = .AN;
        },
        else => {},
    };
    // W4: a single separator between two numbers of the same kind joins them.
    var k: usize = 1;
    while (k + 1 < len) : (k += 1) {
        const t = types[seq[k]];
        if (t != .ES and t != .CS) continue;
        const p = types[seq[k - 1]];
        const nx = types[seq[k + 1]];
        if (p == .EN and nx == .EN) {
            types[seq[k]] = .EN;
        } else if (t == .CS and p == .AN and nx == .AN) {
            types[seq[k]] = .AN;
        }
    }
    // W5: terminators next to EN become EN.
    k = 0;
    while (k < len) {
        if (types[seq[k]] != .ET) {
            k += 1;
            continue;
        }
        var end = k;
        while (end < len and types[seq[end]] == .ET) end += 1;
        if ((k > 0 and types[seq[k - 1]] == .EN) or (end < len and types[seq[end]] == .EN)) {
            for (seq[k..end]) |i| types[i] = .EN;
        }
        k = end;
    }
    // W6: leftover separators and terminators become ON.
    for (seq) |i| switch (types[i]) {
        .ES, .ET, .CS => types[i] = .ON,
        else => {},
    };
    // W7: EN after L becomes L.
    last_strong = sos;
    for (seq) |i| switch (types[i]) {
        .L, .R => last_strong = types[i],
        .EN => if (last_strong == .L) {
            types[i] = .L;
        },
        else => {},
    };

    // N0: paired brackets (BD16 pairing, then resolve each pair in order of its opener).
    const none = std.math.maxInt(usize);
    @memset(cx.closer_of[0..len], none);
    var stack: [63]struct { closing: u21, pos: usize } = undefined;
    var sp: usize = 0;
    for (seq, 0..) |i, pos| {
        if (types[i] != .ON) continue;
        const b = bracketOf(cx.cps[i]) orelse continue;
        if (b.open) {
            if (sp == stack.len) break;
            stack[sp] = .{ .closing = canonBracket(b.pair), .pos = pos };
            sp += 1;
        } else {
            const me = canonBracket(cx.cps[i]);
            var j = sp;
            while (j > 0) {
                j -= 1;
                if (stack[j].closing == me) {
                    cx.closer_of[stack[j].pos] = pos;
                    sp = j;
                    break;
                }
            }
        }
    }
    for (0..len) |open| {
        const close = cx.closer_of[open];
        if (close == none) continue;
        var found_e = false;
        var found_o = false;
        for (seq[open + 1 .. close]) |i| {
            const d = strongDir(types[i]) orelse continue;
            if (d == e) {
                found_e = true;
                break;
            }
            found_o = true;
        }
        var new: Class = undefined;
        if (found_e) {
            new = e;
        } else if (found_o) {
            var context: Class = sos;
            var m = open;
            while (m > 0) {
                m -= 1;
                if (strongDir(types[seq[m]])) |d| {
                    context = d;
                    break;
                }
            }
            new = if (context != e) context else e;
        } else continue;
        for ([_]usize{ open, close }) |p| {
            types[seq[p]] = new;
            // Characters that were NSM before W1 follow their bracket.
            var q = p + 1;
            while (q < len and cx.orig[seq[q]] == .NSM) : (q += 1) types[seq[q]] = new;
        }
    }

    // N1, N2: a run of neutrals takes the direction of its neighbours if they agree, else the embedding direction.
    k = 0;
    while (k < len) {
        if (!isNeutralOrIsolate(types[seq[k]])) {
            k += 1;
            continue;
        }
        var end = k;
        while (end < len and isNeutralOrIsolate(types[seq[end]])) end += 1;
        const lead = if (k == 0) sos else strongDir(types[seq[k - 1]]) orelse e;
        const trail = if (end == len) eos else strongDir(types[seq[end]]) orelse e;
        const new = if (lead == trail) lead else e;
        for (seq[k..end]) |i| types[i] = new;
        k = end;
    }

    // I1, I2: implicit levels.
    for (seq) |i| {
        cx.levels[i] = if (level & 1 == 0) switch (types[i]) {
            .R => level + 1,
            .AN, .EN => level + 2,
            else => level,
        } else switch (types[i]) {
            .L, .EN, .AN => level + 1,
            else => level,
        };
    }
}

/// Rule L2: writes the logical indices of `levels` in left-to-right visual order. `order.len`
/// must equal `levels.len`. Callers drop removed characters afterwards; that does not change
/// the relative order of the others.
pub fn reorder(levels: []const u8, order: []usize) void {
    std.debug.assert(order.len == levels.len);
    for (order, 0..) |*o, i| o.* = i;
    var highest: u8 = 0;
    var lowest_odd: u8 = 255;
    for (levels) |l| {
        highest = @max(highest, l);
        if (l & 1 == 1) lowest_odd = @min(lowest_odd, l);
    }
    if (lowest_odd == 255) return; // no odd level: every reversal would be undone by another
    var level = highest;
    while (level >= lowest_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < levels.len) {
            if (levels[i] < level) {
                i += 1;
                continue;
            }
            var end = i;
            while (end < levels.len and levels[end] >= level) end += 1;
            std.mem.reverse(usize, order[i..end]);
            i = end;
        }
    }
}

// ---- tests ----

const testing = std.testing;

fn decode(buf: []u21, text: []const u8) ![]u21 {
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |c| : (n += 1) buf[n] = c;
    return buf[0..n];
}

/// `want` is one digit per code point.
fn expectLevels(text: []const u8, dir: Direction, want_para: u8, want: []const u8) !void {
    var cp_buf: [64]u21 = undefined;
    const cps = try decode(&cp_buf, text);
    var levels: [64]u8 = undefined;
    const para = try resolve(testing.allocator, cps, dir, levels[0..cps.len]);
    var got: [64]u8 = undefined;
    for (levels[0..cps.len], 0..) |l, i| got[i] = '0' + l;
    try testing.expectEqualStrings(want, got[0..cps.len]);
    try testing.expectEqual(want_para, para);
}

test "class lookup: explicit, default for unassigned RTL blocks, then L" {
    try testing.expectEqual(Class.L, classOf('a'));
    try testing.expectEqual(Class.R, classOf(0x05D0)); // alef
    try testing.expectEqual(Class.AL, classOf(0x0627)); // arabic alef
    try testing.expectEqual(Class.AN, classOf(0x0660)); // arabic-indic zero
    try testing.expectEqual(Class.EN, classOf('1'));
    try testing.expectEqual(Class.NSM, classOf(0x064E)); // fatha
    try testing.expectEqual(Class.WS, classOf(' '));
    try testing.expectEqual(Class.RLI, classOf(0x2067));
    try testing.expectEqual(Class.BN, classOf(0x200D)); // zwj
    try testing.expectEqual(Class.R, classOf(0x05FF)); // unassigned in the Hebrew block
    try testing.expectEqual(Class.AL, classOf(0x07BF)); // unassigned at the end of the Thaana block
    try testing.expectEqual(Class.L, classOf(0x10FFFD)); // plane 16 private use
}

test "tables are sorted and disjoint" {
    inline for (.{ tables.classes, tables.defaults }) |t| {
        for (t[1..], 0..) |r, i| {
            try testing.expect(r.lo <= r.hi);
            try testing.expect(r.lo > t[i].hi);
        }
    }
    for (tables.brackets[1..], 0..) |b, i| try testing.expect(b.cp > tables.brackets[i].cp);
}

test "section 4.7 samples: levels" {
    // Arabic first: the paragraph is RTL, the Latin and digits are LTR islands at level 2.
    try expectLevels("مرحبا world 123", .auto, 1, "111111222222222");
    // Latin first: the paragraph is LTR, the Arabic word is an RTL island; the dot after it is L.
    try expectLevels("ls ملف.txt", .auto, 0, "0001110000");
    // Box row forced LTR (brief 4.4): the bars stay at level 0, the Arabic word is level 1.
    try expectLevels("│ مرحبا    │", .ltr, 0, "001111100000");
    // Arabic-Indic digits (AN) are level 2 in an RTL paragraph; the brackets pair around Arabic (N0) and stay level 1.
    try expectLevels("النتيجة: ١٢٣ (ناجح)", .auto, 1, "1111111112221111111");
    // Tashkeel (NSM) takes the level of its base letter.
    try expectLevels("مُحَمَّد", .auto, 1, "11111111");
}

test "reorder: reverses runs from the highest level down" {
    var order: [5]usize = undefined;
    reorder(&.{ 1, 1, 1, 2, 2 }, &order);
    try testing.expectEqualSlices(usize, &.{ 3, 4, 2, 1, 0 }, &order);
    reorder(&.{ 0, 0, 1, 1, 0 }, &order);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3, 2, 4 }, &order);
}

test {
    _ = @import("conformance.zig");
}
