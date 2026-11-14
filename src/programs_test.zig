//! Real programs (vim, less, fzf, tmux, htop) run through a real PTY and `Session`: smoke tests of observable outcomes,
//! not of looks. A test skips with a message when its program is not installed. Tests only; nothing here ships.
const std = @import("std");
const term = @import("term.zig");
const vt = @import("vt.zig");
const Session = term.Session;

fn have(name: []const u8) bool {
    const path = std.c.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, std.mem.span(path), ':');
    var buf: [512]u8 = undefined;
    while (it.next()) |dir| {
        const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (std.c.access(p, 1) == 0) return true; // X_OK
    }
    return false;
}

fn skipUnless(name: []const u8) !void {
    if (!have(name)) {
        std.debug.print("skipped: {s} is not installed\n", .{name});
        return error.SkipZigTest;
    }
}

fn sleepMs(ms: u32) void {
    const ts: std.c.timespec = .{ .sec = ms / 1000, .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// True if any visible row contains `needle`.
fn screenHas(s: *Session, needle: []const u8) bool {
    const t = s.lock();
    defer s.unlock();
    var buf: [1024]u8 = undefined;
    const rows = t.size().rows;
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        if (std.mem.indexOf(u8, t.rowText(r, &buf), needle) != null) return true;
    }
    return false;
}

fn waitHas(s: *Session, needle: []const u8, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 20) {
        if (screenHas(s, needle)) return true;
        sleepMs(20);
    }
    return screenHas(s, needle);
}

/// Waits until visible row `row` contains `needle`.
fn waitRowHas(s: *Session, row: u16, needle: []const u8, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (true) {
        {
            const t = s.lock();
            defer s.unlock();
            var buf: [1024]u8 = undefined;
            if (std.mem.indexOf(u8, t.rowText(row, &buf), needle) != null) return true;
        }
        if (waited >= timeout_ms) return false;
        sleepMs(20);
        waited += 20;
    }
}

fn waitExit(s: *Session, timeout_ms: u32) ?u8 {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 20) {
        if (s.exitStatus()) |st| return st;
        sleepMs(20);
    }
    return s.exitStatus();
}

fn tmpDir() []const u8 {
    return if (std.c.getenv("TMPDIR")) |d| std.mem.trimEnd(u8, std.mem.span(d), "/") else "/tmp";
}

/// Starts `/bin/sh -c <script>` on a 80x24 terminal. `{d}` in the script is replaced by this process's id, so two
/// runs never share a temp file.
fn run(buf: []u8, comptime fmt: []const u8, args: anytype) !*Session {
    const script = try std.fmt.bufPrintSentinel(buf, fmt, args, 0);
    return Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
}

test "program: vim edits and saves a file" {
    try skipUnless("vim");
    var buf: [512]u8 = undefined;
    const s = try run(&buf, "F={s}/harf-vim-{d}; printf 'start\\n' > $F; vim -u NONE -N -n $F; echo ----; cat $F; rm -f $F; echo FINISHED", .{ tmpDir(), std.c.getpid() });
    defer s.deinit();
    try std.testing.expect(waitHas(s, "start", 10_000)); // vim is up and showing the file
    try s.input("A harf edit\x1b:wq\r");
    try std.testing.expect(waitHas(s, "FINISHED", 10_000));
    try std.testing.expect(screenHas(s, "start harf edit")); // the saved content, printed by cat
    try std.testing.expectEqual(@as(?u8, 0), waitExit(s, 5_000));
}

test "program: vim shows syntax colors and takes the wheel" {
    try skipUnless("vim");
    var buf: [640]u8 = undefined;
    const s = try run(&buf, "F={s}/harf-vimc-{d}.sh; (printf 'echo \"hi\"\\nif true; then\\nfi\\n'; seq 1 120 | sed 's/^/line /') > $F; vim -u NONE -N -n -c 'set mouse=a' $F; rm -f $F", .{ tmpDir(), std.c.getpid() });
    defer s.deinit();
    try std.testing.expect(waitHas(s, "if true", 10_000));
    try s.input(":syntax on\r:set ft=sh\r");
    sleepMs(800);
    var colored = false;
    {
        const t = s.lock();
        defer s.unlock();
        _ = t.update();
        var cps: [16]u21 = undefined;
        const sz = t.size();
        var r: u16 = 0;
        while (r < sz.rows and !colored) : (r += 1) {
            if (!t.selectRow(r)) continue;
            var c: u16 = 0;
            while (c < sz.cols) : (c += 1) {
                if (t.cellInRow(c, &cps).style.fg != null) {
                    colored = true;
                    break;
                }
            }
        }
    }
    try std.testing.expect(colored); // a keyword is drawn with a color of its own
    // mouse: vim asked for tracking, so a wheel notch reaches it and the window scrolls
    var waited: u32 = 0;
    while (waited < 5_000) : (waited += 20) {
        const t = s.lock();
        const on = t.mouseTracking();
        s.unlock();
        if (on) break;
        sleepMs(20);
    }
    try s.input("gg"); // top of the file
    sleepMs(200);
    try s.scroll(9); // three wheel-down events at the pointer
    var scrolled = false;
    waited = 0;
    while (waited < 5_000 and !scrolled) : (waited += 50) {
        sleepMs(50);
        scrolled = !screenHas(s, "echo \"hi\""); // the first line has scrolled off
    }
    try std.testing.expect(scrolled);
    try s.input(":q!\r");
    try std.testing.expectEqual(@as(?u8, 0), waitExit(s, 10_000));
}

test "program: the alternate screen is restored after vim, less, and a killed vim" {
    try skipUnless("vim");
    try skipUnless("less");
    var buf: [900]u8 = undefined;
    // vim quits normally, less quits normally, then a vim is killed with SIGKILL; the markers must come back each time
    const s = try run(&buf,
        "P={s}/harf-pid-{d}; F={s}/harf-alt-{d}; seq 1 50 > $F; echo MARK1; echo MARK2; echo MARK3; sleep 1; " ++
            "vim -u NONE -N -n $F; echo AFTERVIM; sleep 1; less $F; echo AFTERLESS; sleep 1; " ++
            "sh -c \"echo \\$\\$ > $P; exec vim -u NONE -N -n $F\"; printf '\\033[?1049l\\033[?1000l\\033[?25h'; echo AFTERKILL; rm -f $F $P; sleep 3",
        .{ tmpDir(), std.c.getpid(), tmpDir(), std.c.getpid() });
    defer s.deinit();
    try std.testing.expect(waitHas(s, "MARK3", 10_000));
    var total_before: usize = 0;
    {
        const t = s.lock();
        defer s.unlock();
        total_before = t.viewport().total;
    }
    // vim up (it shows the file's lines and '~' filler or the file), then :q
    try std.testing.expect(waitHas(s, "10", 10_000)); // line 10 of the file is visible in vim's window
    try s.input(":q\r");
    try std.testing.expect(waitHas(s, "AFTERVIM", 10_000));
    try std.testing.expect(screenHas(s, "MARK1") and screenHas(s, "MARK2") and screenHas(s, "MARK3")); // the primary screen is back
    // less starts after the script's pause; its page is up when the file's first line is on screen and AFTERVIM is gone
    sleepMs(1800);
    try s.input("q");
    try std.testing.expect(waitHas(s, "AFTERLESS", 10_000));
    try std.testing.expect(screenHas(s, "MARK1"));
    // a vim killed with SIGKILL leaves the alternate screen on; once the shell resets it the markers are readable again
    var pid: std.c.pid_t = 0;
    var waited: u32 = 0;
    while (waited < 10_000 and pid == 0) : (waited += 50) {
        sleepMs(50);
        var pbuf: [512]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/harf-pid-{d}", .{ tmpDir(), std.c.getpid() }, 0) catch unreachable;
        const fd = std.c.open(path, .{}, @as(c_uint, 0));
        if (fd < 0) continue;
        defer _ = std.c.close(fd);
        var line: [32]u8 = undefined;
        const n = std.c.read(fd, &line, line.len);
        if (n > 0) pid = std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, line[0..@intCast(n)], " \r\n"), 10) catch 0;
    }
    try std.testing.expect(pid > 1);
    sleepMs(600); // let vim paint its screen
    _ = std.c.kill(pid, .KILL);
    try std.testing.expect(waitHas(s, "AFTERKILL", 10_000));
    try std.testing.expect(screenHas(s, "MARK1"));
    // nothing of any program's screens went into the scrollback of the primary screen
    const t = s.lock();
    defer s.unlock();
    try std.testing.expect(t.viewport().total <= total_before + 3); // the few lines the shell printed, not vim's or less's pages
}

test "program: less pages and exits" {
    try skipUnless("less");
    var buf: [400]u8 = undefined;
    const s = try run(&buf, "F={s}/harf-less-{d}; seq 1 300 | sed 's/^/line /' > $F; less $F; rm -f $F", .{ tmpDir(), std.c.getpid() });
    defer s.deinit();
    try std.testing.expect(waitHas(s, "line 1", 10_000));
    try s.input(" "); // a page down
    try std.testing.expect(waitHas(s, "line 25", 10_000)); // 23 rows of text are one page
    try s.input("q");
    try std.testing.expectEqual(@as(?u8, 0), waitExit(s, 10_000));
}

test "program: fzf filters and selects" {
    try skipUnless("fzf");
    var buf: [400]u8 = undefined;
    const s = try run(&buf, "printf 'alpha\\nbeta\\ngamma\\ndelta\\n' | fzf --height=100% --no-sort > {s}/harf-fzf-{d}; echo PICKED:$(cat {s}/harf-fzf-{d}); rm -f {s}/harf-fzf-{d}", .{ tmpDir(), std.c.getpid(), tmpDir(), std.c.getpid(), tmpDir(), std.c.getpid() });
    defer s.deinit();
    try std.testing.expect(waitHas(s, "gamma", 10_000)); // the list is up
    try s.input("gam");
    sleepMs(300);
    try s.input("\r");
    try std.testing.expect(waitHas(s, "PICKED:gamma", 10_000));
    try std.testing.expectEqual(@as(?u8, 0), waitExit(s, 5_000));
}

test "program: tmux splits and detaches" {
    try skipUnless("tmux");
    var buf: [500]u8 = undefined;
    const s = try run(&buf, "N=harf{d}; tmux -L $N -f /dev/null new-session; tmux -L $N kill-server 2>/dev/null; echo TMUXDONE", .{std.c.getpid()});
    defer s.deinit();
    try std.testing.expect(waitHas(s, "[0]", 10_000)); // tmux's status line
    try s.input("\x02%"); // prefix, then a vertical split
    sleepMs(600);
    try std.testing.expect(screenHas(s, "\u{2502}")); // the line-drawing border between the two panes (ESC ( 0 mapped)
    try s.input("\x02d"); // detach
    try std.testing.expect(waitHas(s, "TMUXDONE", 10_000));
}

test "program: htop starts and quits" {
    try skipUnless("htop");
    var buf: [200]u8 = undefined;
    const s = try run(&buf, "htop; echo HTOPDONE", .{});
    defer s.deinit();
    try std.testing.expect(waitHas(s, "CPU", 10_000) or waitHas(s, "Tasks", 5_000));
    try s.input("q");
    try std.testing.expect(waitHas(s, "HTOPDONE", 10_000));
}

test "program: a resize storm while vim repaints ends with a correct grid" {
    try skipUnless("vim");
    var buf: [400]u8 = undefined;
    const s = try run(&buf, "F={s}/harf-storm-{d}; seq 1 200 > $F; vim -u NONE -N -n -c 'set ruler' $F; rm -f $F", .{ tmpDir(), std.c.getpid() });
    defer s.deinit();
    try std.testing.expect(waitHas(s, "1,1", 10_000)); // the ruler: vim is up
    for (0..200) |i| {
        if (i % 2 == 0) try s.resize(60, 20, 8, 16) else try s.resize(140, 50, 8, 16);
    }
    try s.resize(100, 30, 8, 16);
    // vim repaints for the final size: its ruler lands on the last row of the 30-row grid
    try std.testing.expect(waitRowHas(s, 29, "1,1", 10_000));
    {
        const t = s.lock();
        defer s.unlock();
        const sz = t.size();
        try std.testing.expectEqual(@as(u16, 100), sz.cols);
        try std.testing.expectEqual(@as(u16, 30), sz.rows);
        try std.testing.expect(t.cursor() != null and t.cursor().?.row < 30 and t.cursor().?.col < 100); // nothing outside the grid
    }
    try s.input(":q!\r");
    try std.testing.expectEqual(@as(?u8, 0), waitExit(s, 10_000));
}
