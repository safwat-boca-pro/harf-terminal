//! PTY wrapper: starts a child on a pseudo-terminal and moves bytes, window size and exit status.
const std = @import("std");
const c = std.c;

// forkpty and ioctl live in libSystem but not in std.c.
extern "c" fn forkpty(amaster: *c_int, name: ?[*]u8, termp: ?*const c.termios, winp: ?*const c.winsize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
/// _IOW('t', 103, struct winsize) on Darwin; std.c.T has no entry for macOS.
const TIOCSWINSZ: c_ulong = 0x80087467;
const TIOCGPGRP: c_ulong = 0x40047477;
const O_NONBLOCK: c_int = 0x4;
extern "c" fn signal(sig: c_int, handler: ?*const anyopaque) ?*const anyopaque;
extern "c" fn sigprocmask(how: c_int, set: ?*const u32, old: ?*u32) c_int;

/// Held from `forkpty` until the new master is close-on-exec, so a spawn on another thread cannot
/// fork a child that inherits this master.
var spawn_lock: c.pthread_mutex_t = .{};

pub const SpawnOptions = struct {
    /// `argv[0]` is the program to run, as a path (no PATH lookup).
    argv: []const [:0]const u8,
    /// What the program sees as its own name, when different from `argv[0]` (a login shell is "-zsh").
    argv0: ?[:0]const u8 = null,
    cols: u16 = 80,
    rows: u16 = 24,
    cwd: ?[:0]const u8 = null,
    /// A directory holding `zsh/.zshenv` (Harf's shell integration). When set and the program is zsh, the child starts with
    /// `ZDOTDIR` pointing there and its own `ZDOTDIR` kept in `HARF_ORIG_ZDOTDIR`; any other program is left alone.
    shell_integration_dir: ?[:0]const u8 = null,
};

/// The shell integration directory the login shell gets (`spawnShell`); null means none.
/// ponytail: process-wide, set by the app from its config; make it a per-window setting if that is ever needed.
pub var default_shell_integration_dir: ?[:0]const u8 = null;

fn isZsh(path: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    return std.mem.eql(u8, base, "zsh");
}

/// Marks `fd` close-on-exec, so children started later do not inherit it. Without this a second
/// session's shell would hold the first session's PTY master open and never see it hang up.
/// Makes reads and writes on `fd` return EAGAIN instead of waiting.
pub fn setNonblock(fd: c_int) void {
    const flags = c.fcntl(fd, 3, @as(c_int, 0)); // F_GETFL
    if (flags >= 0) _ = c.fcntl(fd, 4, flags | O_NONBLOCK); // F_SETFL
}

fn waitReady(fd: c_int, events: i16) void {
    var p = [1]c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    _ = c.poll(&p, 1, -1);
}

pub fn setCloexec(fd: c_int) void {
    const f_setfd = 2; // F_SETFD
    const fd_cloexec = 1; // FD_CLOEXEC
    _ = c.fcntl(fd, f_setfd, @as(c_int, fd_cloexec));
}

/// "-zsh" for "/bin/zsh": the name a login shell is started under. The result is a slice of `buf`.
pub fn loginArgv0(buf: []u8, shell: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, shell, '/')) |i| shell[i + 1 ..] else shell;
    buf[0] = '-';
    @memcpy(buf[1..][0..base.len], base);
    return buf[0 .. 1 + base.len];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

/// The parent's environment with the terminal variables replaced, and a UTF-8 LANG if none is set. With `integration` (the shell
/// integration directory, for zsh) `ZDOTDIR` points at its `zsh` folder and the user's own is kept in `HARF_ORIG_ZDOTDIR`.
fn buildEnv(arena: std.mem.Allocator, integration: ?[:0]const u8) ![:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var have_locale = false;
    var orig_zdotdir: []const u8 = "";
    var i: usize = 0;
    while (c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.sliceTo(entry, 0);
        if (startsWith(s, "TERM=") or startsWith(s, "COLORTERM=") or startsWith(s, "TERM_PROGRAM=")) continue;
        if (integration != null) {
            if (startsWith(s, "ZDOTDIR=")) {
                orig_zdotdir = s["ZDOTDIR=".len..];
                continue;
            }
            if (startsWith(s, "HARF_ORIG_ZDOTDIR=") or startsWith(s, "HARF_SHELL_INTEGRATION=")) continue;
        }
        if (startsWith(s, "LANG=") or startsWith(s, "LC_ALL=")) have_locale = true;
        try list.append(arena, entry);
    }
    try list.append(arena, "TERM=xterm-256color");
    try list.append(arena, "COLORTERM=truecolor");
    try list.append(arena, "TERM_PROGRAM=Harf");
    if (!have_locale) try list.append(arena, "LANG=en_US.UTF-8");
    if (integration) |dir| {
        try list.append(arena, (try std.fmt.allocPrintSentinel(arena, "ZDOTDIR={s}/zsh", .{dir}, 0)).ptr);
        try list.append(arena, (try std.fmt.allocPrintSentinel(arena, "HARF_ORIG_ZDOTDIR={s}", .{orig_zdotdir}, 0)).ptr);
        try list.append(arena, "HARF_SHELL_INTEGRATION=1");
    }
    return list.toOwnedSliceSentinel(arena, null);
}

fn decodeStatus(raw: c_int) u8 {
    const st: u32 = @bitCast(raw);
    if (c.W.IFEXITED(st)) return c.W.EXITSTATUS(st);
    return @intCast(@min(255, 128 + @as(u32, @intFromEnum(c.W.TERMSIG(st)))));
}

pub const Pty = struct {
    /// Master side of the pseudo-terminal: read the child's output, write its input.
    fd: c_int,
    pid: c.pid_t,
    status: ?u8 = null,
    /// The terminal's foreground process group when teardown began. With job control it is a job's
    /// own group, not the shell's, so it needs its own signals. 0 = none or the shell's group.
    fg: c.pid_t = 0,

    pub fn spawn(gpa: std.mem.Allocator, opts: SpawnOptions) !Pty {
        std.debug.assert(opts.argv.len > 0);
        // Everything the child needs is built before forking: after forkpty the child may only
        // call async-signal-safe functions.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const argv = try arena.allocSentinel(?[*:0]const u8, opts.argv.len, null);
        for (opts.argv, 0..) |a, i| argv[i] = a.ptr;
        if (opts.argv0) |a0| argv[0] = a0.ptr;
        const integration = if (opts.shell_integration_dir) |d| (if (isZsh(opts.argv[0])) d else null) else null;
        const envp = try buildEnv(arena, integration);

        var ws: c.winsize = .{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 };
        var master: c_int = -1;
        _ = c.pthread_mutex_lock(&spawn_lock);
        const pid = forkpty(&master, null, null, &ws);
        if (pid < 0) {
            _ = c.pthread_mutex_unlock(&spawn_lock);
            return error.ForkptyFailed;
        }
        if (pid == 0) {
            // Child. IUTF8 makes the line discipline erase whole UTF-8 characters (Arabic letters are two bytes).
            var t: c.termios = undefined;
            if (c.tcgetattr(0, &t) == 0) {
                t.iflag.IUTF8 = true;
                _ = c.tcsetattr(0, .NOW, &t);
            }
            // Start from default signal handling: the parent (an AppKit app) may ignore or block signals.
            var sig: c_int = 1;
            while (sig < 32) : (sig += 1) _ = signal(sig, null);
            const no_signals: u32 = 0;
            _ = sigprocmask(3, &no_signals, null); // SIG_SETMASK
            if (opts.cwd) |dir| {
                if (c.chdir(dir.ptr) != 0) _ = c.chdir("/");
            }
            _ = c.execve(opts.argv[0].ptr, argv.ptr, envp.ptr);
            c._exit(127);
        }
        setCloexec(master);
        _ = c.pthread_mutex_unlock(&spawn_lock);
        setNonblock(master); // reads and writes go through poll; see read, write and writeSome
        return .{ .fd = master, .pid = pid };
    }

    /// The user's login shell (`$SHELL`, else /bin/zsh) in `cwd`, or in `$HOME` if there is none (or it cannot be entered).
    pub fn spawnShell(gpa: std.mem.Allocator, cols: u16, rows: u16, cwd: ?[:0]const u8) !Pty {
        const shell: [:0]const u8 = if (c.getenv("SHELL")) |s| std.mem.span(s) else "/bin/zsh";
        const home: [:0]const u8 = cwd orelse if (c.getenv("HOME")) |h| std.mem.span(h) else "/";
        var name_buf: [256]u8 = undefined;
        if (shell.len + 2 > name_buf.len) return error.ShellPathTooLong;
        const name = loginArgv0(&name_buf, shell);
        name_buf[name.len] = 0;
        return spawn(gpa, .{
            .argv = &.{shell},
            .argv0 = name_buf[0..name.len :0],
            .cols = cols,
            .rows = rows,
            .cwd = home,
            .shell_integration_dir = default_shell_integration_dir,
        });
    }

    /// Blocks until output arrives. Returns 0 when the child has closed its side (end of output).
    pub fn read(self: *Pty, buf: []u8) !usize {
        while (true) {
            const n = c.read(self.fd, buf.ptr, buf.len);
            if (n >= 0) return @intCast(n);
            switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => waitReady(self.fd, c.POLL.IN),
                .IO => return 0, // macOS reports the closed slave as EIO
                else => return error.ReadFailed,
            }
        }
    }

    /// Sends all of `bytes` to the child, blocking while the child is not reading.
    pub fn write(self: *Pty, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.write(self.fd, rest.ptr, rest.len);
            if (n < 0) {
                switch (std.posix.errno(n)) {
                    .INTR => continue,
                    .AGAIN => {
                        waitReady(self.fd, c.POLL.OUT);
                        continue;
                    },
                    else => return error.WriteFailed,
                }
            }
            rest = rest[@intCast(n)..];
        }
    }

    /// One write that never waits: returns how many bytes the child's input queue took (0 if it is full).
    pub fn writeSome(self: *Pty, bytes: []const u8) !usize {
        while (true) {
            const n = c.write(self.fd, bytes.ptr, bytes.len);
            if (n >= 0) return @intCast(n);
            switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return 0,
                else => return error.WriteFailed,
            }
        }
    }

    /// Sets the window size; the kernel then signals the child with SIGWINCH.
    pub fn resize(self: *Pty, cols: u16, rows: u16, px_w: u16, px_h: u16) !void {
        var ws: c.winsize = .{ .row = rows, .col = cols, .xpixel = px_w, .ypixel = px_h };
        if (ioctl(self.fd, TIOCSWINSZ, &ws) != 0) return error.ResizeFailed;
    }

    /// Waits for the child and returns its exit code (128 + signal if it was killed). Cached.
    pub fn wait(self: *Pty) u8 {
        if (self.status) |s| return s;
        var raw: c_int = 0;
        while (true) {
            const r = c.waitpid(self.pid, &raw, 0);
            if (r == self.pid) {
                self.status = decodeStatus(raw);
                return self.status.?;
            }
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            self.status = 255; // already reaped elsewhere, or not our child
            return 255;
        }
    }

    /// Records the terminal's foreground process group (it is gone once the master is closed).
    fn noteForeground(self: *Pty) void {
        if (self.fd < 0) return;
        var pg: c.pid_t = 0;
        if (ioctl(self.fd, TIOCGPGRP, &pg) == 0 and pg > 1 and pg != self.pid) self.fg = pg;
    }

    fn signalGroups(self: *Pty, sig: anytype) void {
        _ = c.kill(-self.pid, sig); // the child is a session leader, so its pid is its group id
        if (self.fg != 0) _ = c.kill(-self.fg, sig);
    }

    /// Hangs up on the child's process group and on the terminal's foreground job (SIGHUP, as
    /// closing a terminal would) and reaps the child. Whatever is still running after 100 ms gets
    /// SIGKILL. For teardown only: this is the one bounded wait in the product.
    pub fn kill(self: *Pty) void {
        if (self.status != null) return;
        self.noteForeground();
        self.signalGroups(.HUP);
        var tries: u32 = 0;
        while (tries < 10) : (tries += 1) {
            var raw: c_int = 0;
            const r = c.waitpid(self.pid, &raw, c.W.NOHANG);
            if (r == self.pid) {
                self.status = decodeStatus(raw);
                self.signalGroups(.KILL); // sweep group members that outlived the leader
                return;
            }
            if (r < 0) {
                self.status = 255;
                return;
            }
            const ts: c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = c.nanosleep(&ts, null);
        }
        self.signalGroups(.KILL);
        _ = self.wait();
    }

    /// Reaps the child (hanging up on it if it is still running) and closes the PTY.
    pub fn deinit(self: *Pty) void {
        // Close the master first: a child with unread output on its terminal cannot exit until
        // that output is drained or the master is gone (and the close also hangs up its terminal).
        self.noteForeground(); // the terminal knows its foreground job only while the master is open
        _ = c.close(self.fd);
        self.fd = -1;
        self.kill();
    }
};


fn readAll(p: *Pty, gpa: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try p.read(&buf);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

test "child output arrives" {
    const gpa = std.testing.allocator;
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "printf hello" } });
    defer p.deinit();
    const out = try readAll(&p, gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "exit code" {
    const gpa = std.testing.allocator;
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "exit 3" } });
    defer p.deinit();
    gpa.free(try readAll(&p, gpa));
    try std.testing.expectEqual(@as(u8, 3), p.wait());
}

test "child environment" {
    const gpa = std.testing.allocator;
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "printf \"%s:%s:%s\" \"$TERM\" \"$COLORTERM\" \"$TERM_PROGRAM\"" } });
    defer p.deinit();
    const out = try readAll(&p, gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("xterm-256color:truecolor:Harf", out);
}

test "shell integration points ZDOTDIR at the shim for zsh only" {
    const gpa = std.testing.allocator;
    const script = "printf \"[%s|%s]\" \"$ZDOTDIR\" \"$HARF_SHELL_INTEGRATION\"";
    var sh = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", script }, .shell_integration_dir = "/opt/harf" });
    defer sh.deinit();
    const not_zsh = try readAll(&sh, gpa);
    defer gpa.free(not_zsh);
    try std.testing.expect(std.mem.indexOf(u8, not_zsh, "/opt/harf") == null and std.mem.indexOf(u8, not_zsh, "|1]") == null);

    var z = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/zsh", "-f", "-c", script }, .shell_integration_dir = "/opt/harf" });
    defer z.deinit();
    const zsh = try readAll(&z, gpa);
    defer gpa.free(zsh);
    try std.testing.expectEqualStrings("[/opt/harf/zsh|1]", zsh);
}

test "resize reaches the child" {
    const gpa = std.testing.allocator;
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "sleep 0.3; stty size" }, .cols = 80, .rows = 24 });
    defer p.deinit();
    try p.resize(100, 30, 0, 0);
    const out = try readAll(&p, gpa);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "30 100") != null);
}

test "child runs in UTF-8 mode so Backspace erases whole characters" {
    const gpa = std.testing.allocator;
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "stty -a | grep -c iutf8" } });
    defer p.deinit();
    const out = try readAll(&p, gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("1\r\n", out);
}

test "login argv0" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("-zsh", loginArgv0(&buf, "/bin/zsh"));
}

test "a child does not inherit another session's PTY" {
    const gpa = std.testing.allocator;
    var a = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sleep", "60" } });
    defer a.deinit();
    // `: <&N` succeeds only if descriptor N is open in the child.
    var script_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(&script_buf, "if (: <&{d}) 2>/dev/null; then echo leaked; else echo clean; fi", .{a.fd}, 0);
    var b = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer b.deinit();
    const out = try readAll(&b, gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("clean\r\n", out);
}

fn nowMs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// Reads until the output contains `needle` (or the child ends). Test helper.
fn readUntil(p: *Pty, needle: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len and std.mem.indexOf(u8, buf[0..n], needle) == null) {
        const got = p.read(buf[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    return buf[0..n];
}

test "kill escalates past a child that ignores SIGHUP" {
    const gpa = std.testing.allocator;
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "trap '' HUP; echo ready; while :; do sleep 1; done" } });
    var buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, readUntil(&p, "ready", &buf), "ready") != null);
    const pid = p.pid;
    const t0 = nowMs();
    p.deinit();
    try std.testing.expect(nowMs() - t0 < 500);
    var raw: c_int = 0;
    try std.testing.expect(c.waitpid(pid, &raw, c.W.NOHANG) < 0); // already reaped: ECHILD
}

test "kill reaches the process group" {
    const gpa = std.testing.allocator;
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "sleep 60 & echo bg:$!:; wait" } });
    var buf: [256]u8 = undefined;
    const out = readUntil(&p, ":\r", &buf);
    const start = (std.mem.indexOf(u8, out, "bg:") orelse return error.NoPid) + 3;
    const end = std.mem.indexOfScalarPos(u8, out, start, ':') orelse return error.NoPid;
    const bg_pid = try std.fmt.parseInt(c.pid_t, out[start..end], 10);
    p.deinit();
    var gone = false;
    var waited: u32 = 0;
    while (waited < 500) : (waited += 10) {
        if (c.kill(bg_pid, @enumFromInt(0)) != 0) {
            gone = true;
            break;
        }
        const ts: c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
    try std.testing.expect(gone);
}

test "kill reaches a foreground job in its own process group that ignores SIGHUP" {
    // With job control the foreground job is not in the shell's process group, so signalling the
    // shell's group alone leaves it running (the nohup case).
    const gpa = std.testing.allocator;
    const script = "set -m; sh -c 'trap \"\" HUP; echo job:$$:; exec sleep 30'";
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", script } });
    var buf: [256]u8 = undefined;
    const out = readUntil(&p, ":\r", &buf);
    const start = (std.mem.indexOf(u8, out, "job:") orelse return error.NoPid) + 4;
    const end = std.mem.indexOfScalarPos(u8, out, start, ':') orelse return error.NoPid;
    const job_pid = try std.fmt.parseInt(c.pid_t, out[start..end], 10);
    p.deinit();
    var gone = false;
    var waited: u32 = 0;
    while (waited < 500) : (waited += 10) {
        if (c.kill(job_pid, @enumFromInt(0)) != 0) {
            gone = true;
            break;
        }
        const ts: c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
    if (!gone) _ = c.kill(job_pid, .KILL); // do not leave a stray sleep behind a failing run
    try std.testing.expect(gone);
}

const FdCount = struct {
    result: i32 = -1,
    fn run(self: *FdCount) void {
        var p = Pty.spawn(std.heap.smp_allocator, .{ .argv = &.{ "/bin/sh", "-c", "ls /dev/fd | wc -l" } }) catch return;
        defer p.deinit();
        const out = readAll(&p, std.heap.smp_allocator) catch return;
        defer std.heap.smp_allocator.free(out);
        self.result = std.fmt.parseInt(i32, std.mem.trim(u8, out, " \r\n"), 10) catch -2;
    }
};

test "concurrent spawns leak no descriptors into each other's children" {
    var base: FdCount = .{};
    base.run();
    try std.testing.expect(base.result > 0);
    var jobs: [8]FdCount = @splat(.{});
    var threads: [8]std.Thread = undefined;
    for (&threads, &jobs) |*t, *j| t.* = try std.Thread.spawn(.{}, FdCount.run, .{j});
    for (threads) |t| t.join();
    for (jobs) |j| try std.testing.expectEqual(base.result, j.result);
}

test "a missing cwd falls back to /" {
    const gpa = std.testing.allocator;
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "pwd" }, .cwd = "/nonexistent-harf" });
    defer p.deinit();
    const out = try readAll(&p, gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("/\r\n", out);
}

test "the child does not inherit ignored signals" {
    const gpa = std.testing.allocator;
    const sig_pipe = 13;
    const sig_ign: ?*const anyopaque = @ptrFromInt(1);
    const old = signal(sig_pipe, sig_ign);
    defer _ = signal(sig_pipe, old);
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "kill -PIPE $$; echo alive" } });
    defer p.deinit();
    const out = try readAll(&p, gpa);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "alive") == null);
}

test "the child does not inherit the signal mask" {
    const gpa = std.testing.allocator;
    const usr1_bit: u32 = 1 << (30 - 1);
    var old: u32 = 0;
    _ = sigprocmask(1, &usr1_bit, &old); // SIG_BLOCK
    defer _ = sigprocmask(3, &old, null); // SIG_SETMASK
    var p = try Pty.spawn(gpa, .{ .argv = &.{ "/bin/sh", "-c", "kill -USR1 $$; echo alive" } });
    defer p.deinit();
    const out = try readAll(&p, gpa);
    defer gpa.free(out);
    // A blocked SIGUSR1 stays pending and the shell lives on; unblocked, the default action ends it.
    try std.testing.expect(std.mem.indexOf(u8, out, "alive") == null);
}
