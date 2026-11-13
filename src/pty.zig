//! PTY wrapper: starts a child on a pseudo-terminal and moves bytes, window size and exit status.
const std = @import("std");
const c = std.c;

// forkpty and ioctl live in libSystem but not in std.c.
extern "c" fn forkpty(amaster: *c_int, name: ?[*]u8, termp: ?*const c.termios, winp: ?*const c.winsize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
/// _IOW('t', 103, struct winsize) on Darwin; std.c.T has no entry for macOS.
const TIOCSWINSZ: c_ulong = 0x80087467;
const O_NONBLOCK: c_int = 0x4;

pub const SpawnOptions = struct {
    /// `argv[0]` is the program to run, as a path (no PATH lookup).
    argv: []const [:0]const u8,
    /// What the program sees as its own name, when different from `argv[0]` (a login shell is "-zsh").
    argv0: ?[:0]const u8 = null,
    cols: u16 = 80,
    rows: u16 = 24,
    cwd: ?[:0]const u8 = null,
};

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

/// The parent's environment with the terminal variables replaced, and a UTF-8 LANG if none is set.
fn buildEnv(arena: std.mem.Allocator) ![:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var have_locale = false;
    var i: usize = 0;
    while (c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.sliceTo(entry, 0);
        if (startsWith(s, "TERM=") or startsWith(s, "COLORTERM=") or startsWith(s, "TERM_PROGRAM=")) continue;
        if (startsWith(s, "LANG=") or startsWith(s, "LC_ALL=")) have_locale = true;
        try list.append(arena, entry);
    }
    try list.append(arena, "TERM=xterm-256color");
    try list.append(arena, "COLORTERM=truecolor");
    try list.append(arena, "TERM_PROGRAM=Harf");
    if (!have_locale) try list.append(arena, "LANG=en_US.UTF-8");
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
        const envp = try buildEnv(arena);

        var ws: c.winsize = .{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 };
        var master: c_int = -1;
        const pid = forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkptyFailed;
        if (pid == 0) {
            // Child. IUTF8 makes the line discipline erase whole UTF-8 characters (Arabic letters are two bytes).
            var t: c.termios = undefined;
            if (c.tcgetattr(0, &t) == 0) {
                t.iflag.IUTF8 = true;
                _ = c.tcsetattr(0, .NOW, &t);
            }
            if (opts.cwd) |dir| _ = c.chdir(dir.ptr);
            _ = c.execve(opts.argv[0].ptr, argv.ptr, envp.ptr);
            c._exit(127);
        }
        setCloexec(master);
        setNonblock(master); // reads and writes go through poll; see read, write and writeSome
        return .{ .fd = master, .pid = pid };
    }

    /// The user's login shell (`$SHELL`, else /bin/zsh) in `$HOME`.
    pub fn spawnShell(gpa: std.mem.Allocator, cols: u16, rows: u16) !Pty {
        const shell: [:0]const u8 = if (c.getenv("SHELL")) |s| std.mem.span(s) else "/bin/zsh";
        const home: [:0]const u8 = if (c.getenv("HOME")) |h| std.mem.span(h) else "/";
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

    /// Hangs up on the child (SIGHUP, as closing a terminal would) and reaps it. A child that
    /// ignores SIGHUP gets SIGKILL after about a second. For teardown only.
    pub fn kill(self: *Pty) void {
        if (self.status != null) return;
        _ = c.kill(self.pid, .HUP);
        var tries: u32 = 0;
        while (tries < 100) : (tries += 1) {
            var raw: c_int = 0;
            const r = c.waitpid(self.pid, &raw, c.W.NOHANG);
            if (r == self.pid) {
                self.status = decodeStatus(raw);
                return;
            }
            if (r < 0) {
                self.status = 255;
                return;
            }
            const ts: c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = c.nanosleep(&ts, null);
        }
        _ = c.kill(self.pid, .KILL);
        _ = self.wait();
    }

    /// Reaps the child (hanging up on it if it is still running) and closes the PTY.
    pub fn deinit(self: *Pty) void {
        // Close the master first: a child with unread output on its terminal cannot exit until
        // that output is drained or the master is gone (and the close also hangs up its terminal).
        _ = c.close(self.fd);
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
