# Phase 3, Slice 1: Headless Terminal Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tested Zig core that runs a child shell on a PTY and keeps its output in a logical-order grid (libghostty-vt), exposed through a small `harf_term_*` C ABI. No UI.

**Architecture:** `src/vt.zig` wraps libghostty-vt's C API (translated by the build system); `src/pty.zig` wraps `forkpty`; `src/term.zig` joins them with one I/O thread, a mutex and a coalesced wake callback; `src/capi.zig` exports it. Swift is not touched except to keep linking.

**Tech Stack:** Zig 0.17.1, libghostty-vt 1.0.1 (release tarball, `simd=false`), libc (`forkpty`, `ioctl`, `waitpid`, pthreads).

**Spec:** `docs/superpowers/specs/2026-11-13-phase3-terminal-core-design.md` (slice 1 of 4). Slices 2 to 4 (window, daily use, conformance and numbers) get their own plans once this one lands, because their shape depends on the API this slice produces.

## Global Constraints

- Zig **0.17.1** pinned; `std` here has no `@cImport`, no `std.Thread.Mutex`, and no fork wrappers: use `b.addTranslateC`, `std.c` pthread and extern declarations (as `src/shape/ct.zig` does for CoreText).
- libghostty-vt **1.0.1** from `https://release.files.ghostty.org/libghostty-vt/1.0.1/libghostty-vt-1.0.1.tar.gz` (SHA-256 `333dfce97641ef9b536bb9e08907ad86abaaada50e8f7417b70d9284adef37aa`, Zig hash `ghostty-1.4.1-dev-5UdBC7mPUgFIzAVXNJOixiryPYogwYwnmN0zZWud4iSr`), built with `.simd = false`, `ghostty-vt-static` artifact, macro `GHOSTTY_STATIC`.
- C API only. Swift never sees libghostty headers; `include/harf.h` stays hand-written.
- Default scrollback **1 MiB** (`1 << 20`); kitty image storage limit **0**.
- Child environment: `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Harf`, UTF-8 `LANG` if unset; login shell from `$SHELL`, cwd `$HOME`.
- Grid stays logical-order. No timers, no polling in product code (tests may poll with a timeout).
- MIT-compatible licenses only; `NOTICE` lists what is actually linked.
- No attribution trailers in commits (user's global rule).

## Review Focus

Inputs the spec implies but no obvious test covers; each has a test in the owning task.

1. A child that prints and exits immediately: no output lost, exit status reported (Task 6, `flood and fast exit`).
2. A flood far larger than the pipe buffer: reader never deadlocks, memory stays bounded by scrollback (Task 6, same test).
3. A UTF-8 sequence split across two reads: identical grid to one write (Task 2).
4. Resize to 1x1 or 500x200, and resizing while output streams: no crash (Tasks 4 and 6).
5. `deinit` while the child is still running: child is killed and reaped, no zombie, no leak (Task 6).

## File Structure

| File | Responsibility |
|---|---|
| `build.zig.zon`, `build.zig` | Dependency, translate-c module `ghostty_c`, link, install archive |
| `src/vt_c.h` | One line: `#include <ghostty/vt.h>` (input to translate-c) |
| `src/vt.zig` | `Terminal`: wrapper over libghostty-vt (grid, cells, scrollback, resize, effects) |
| `src/pty.zig` | `Pty`: forkpty, read, write, resize, wait, kill |
| `src/term.zig` | `Session`: Pty + Terminal + I/O thread + lock + wake |
| `src/capi.zig`, `include/harf.h` | `harf_term_*` exports and declarations |
| `macos/Package.swift` | Link the libghostty archive |
| `NOTICE`, `ARCHITECTURE.md` | Licenses and decision log |

Delete the empty `src/parser.zig` and `src/screen.zig` (libghostty-vt replaces them).

---

### Task 1: Dependency and `vt.Terminal` smoke test

**Files:**
- Modify: `build.zig.zon`, `build.zig`, `src/capi.zig` (test import), `NOTICE`
- Create: `src/vt_c.h`, `src/vt.zig`
- Delete: `src/parser.zig`, `src/screen.zig`

**Interfaces:**
- Produces: `vt.Options = struct { cols: u16 = 80, rows: u16 = 24, scrollback_bytes: usize = 1 << 20, callbacks: Callbacks = .{} }` (`Callbacks` is added in Task 3; until then omit the field);
  `vt.Terminal.init(gpa: std.mem.Allocator, opts: Options) !*Terminal`; `deinit(self: *Terminal) void`; `write(self: *Terminal, bytes: []const u8) void`; `rowText(self: *Terminal, row: u16, out: []u8) []const u8` (UTF-8 of the visible row, trailing blanks trimmed, slice of `out`); `pub const c = @import("ghostty_c")`; field `handle: c.GhosttyTerminal`.

- [ ] **Step 1: Write the failing test** at the bottom of `src/vt.zig` (file does not exist yet), and add `_ = @import("vt.zig");` to the `test {}` block in `src/capi.zig`:

```zig
test "written text lands in row 0" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("hello");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("hello", t.rowText(0, &buf));
    try std.testing.expectEqualStrings("", t.rowText(1, &buf));
}
```

- [ ] **Step 2: Run** `.tools/zig/zig build test`. Expected: FAIL (compile error, `vt.zig` has no `Terminal`).
- [ ] **Step 3: Wire the dependency.** Run `.tools/zig/zig fetch --save=ghostty https://release.files.ghostty.org/libghostty-vt/1.0.1/libghostty-vt-1.0.1.tar.gz`; confirm the saved hash equals the Zig hash above and `shasum -a 256` of the downloaded tarball equals the SHA-256 above. In `build.zig`:

```zig
const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false });
const tc = b.addTranslateC(.{ .root_source_file = b.path("src/vt_c.h"), .target = target, .optimize = optimize });
tc.defineCMacro("GHOSTTY_STATIC", null);
tc.addIncludePath(ghostty.path("include"));
core.addImport("ghostty_c", tc.createModule());
core.linkLibrary(ghostty.artifact("ghostty-vt-static"));
b.installArtifact(ghostty.artifact("ghostty-vt-static"));
```

  If translate-c cannot find libc headers (explicit target disables SDK detection), also `tc.addSystemIncludePath` with `<sdk>/usr/include`, reusing the `getSdk` result `build.zig` already computes.
- [ ] **Step 4: Implement `vt.Terminal`** per the Interfaces block in `src/vt.zig`: `ghostty_terminal_new` (nullptr allocator, `opts.cols`, `opts.rows`), set `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` from `opts.scrollback_bytes` (pointer to a `usize`), `ghostty_terminal_vt_write`. `rowText`: `ghostty_render_state_update`, row iterator and row cells, concatenating each cell's grapheme codepoints (`GRAPHEMES_BUF`) as UTF-8, blank cells as spaces, trailing spaces trimmed. For call order follow `example/c-vt-render/src/main.c` in the Ghostty git repository at tag `vt-1.0.1` (examples are not in the release tarball), or the doc comments in `include/ghostty/vt/render.h`. `Terminal` is heap-allocated (`gpa.create`) so its address is stable for callbacks.
- [ ] **Step 5: Run** `.tools/zig/zig build test`. Expected: PASS. Then `.tools/zig/zig build` succeeds.
- [ ] **Step 6: Licenses.** `nm zig-out/lib/libghostty-vt-static.a | grep -ci 'hwy\|simdutf\|wuffs'` shows which optional packages are really linked. Append to `NOTICE` the verbatim license text of libghostty-vt (MIT) and of each package actually linked (uucode: MIT and Unicode-3.0; plus wuffs, highway or simdutf only if the check found them), taken from the fetched package directories under `~/.cache/zig/p/` and its `deps/libghostty-vt-third-party.json`.
- [ ] **Step 7: Commit**

```bash
git rm -q src/parser.zig src/screen.zig
git add build.zig build.zig.zon src/vt_c.h src/vt.zig src/capi.zig NOTICE
git commit -m "Add libghostty-vt 1.0.1 dependency and vt.Terminal wrapper"
```

---

### Task 2: Cell access and the Arabic grid facts

**Files:** Modify `src/vt.zig`.

**Interfaces:**
- Consumes: Task 1 `Terminal`.
- Produces: `vt.Wide = enum { narrow, wide, spacer_tail, spacer_head }`; `vt.Cell = struct { cps: []const u21, wide: Wide }`; `Terminal.cell(self: *Terminal, col: u16, row: u16, buf: *[16]u21) Cell` (`cps` is a slice of `buf`, empty for a blank cell, truncated to 16).

- [ ] **Step 1: Write the failing tests** (helper `fn expectCps(t: *Terminal, col: u16, row: u16, want: []const u21) !void` compares `t.cell(...).cps`):

```zig
test "arabic: one cell per letter, logical order" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("مرحبا world");
    try expectCps(t, 0, 0, &.{0x645});
    try expectCps(t, 4, 0, &.{0x627});
    try expectCps(t, 5, 0, &.{0x20});
    try expectCps(t, 6, 0, &.{'w'});
}
test "tashkeel lives in its base cell" {
    // fresh 40x10 terminal; write("مُحَمَّد")
    try expectCps(t, 0, 0, &.{ 0x645, 0x64F });
    try expectCps(t, 1, 0, &.{ 0x62D, 0x64E });
    try expectCps(t, 2, 0, &.{ 0x645, 0x64E, 0x651 });
    try expectCps(t, 3, 0, &.{0x62F});
    try expectCps(t, 4, 0, &.{}); // blank
}
test "lam-alef is two cells" { // write("لا")
    try expectCps(t, 0, 0, &.{0x644});
    try expectCps(t, 1, 0, &.{0x627});
}
test "zwnj joins the previous cell" { // write("می‌خواهم")
    try expectCps(t, 1, 0, &.{ 0x6CC, 0x200C });
}
test "emoji is a wide cell plus a spacer" { // write("ok \u{1F600} ok")
    var buf: [16]u21 = undefined;
    try std.testing.expectEqual(Wide.wide, t.cell(3, 0, &buf).wide);
    try std.testing.expectEqualSlices(u21, &.{0x1F600}, t.cell(3, 0, &buf).cps);
    try std.testing.expectEqual(Wide.spacer_tail, t.cell(4, 0, &buf).wide);
}
test "utf-8 split across two writes equals one write" {
    // text = "مرحبا world"; a.write(text); b.write(text[0..5]); b.write(text[5..]);
    // byte 5 falls inside the third Arabic letter (2 bytes each). rowText(0) of a and b are equal and nonempty.
}
```

- [ ] **Step 2: Run** `.tools/zig/zig build test`. Expected: FAIL (`cell` not defined).
- [ ] **Step 3: Implement `Terminal.cell`**: render state row cells at (col,row) (`ROW_CELLS_DATA_RAW` then `ghostty_cell_get(.., GHOSTTY_CELL_DATA_WIDE, ..)`; `GRAPHEMES_BUF` for codepoints). Factor the row/cell iteration shared with `rowText` into one private helper.
- [ ] **Step 4: Run** the suite. Expected: PASS (these pin facts the spike measured; a failure means the library behaves differently than recorded).
- [ ] **Step 5: Commit** `git add src/vt.zig && git commit -m "vt: cell access; pin Arabic grid facts as tests"`

---

### Task 3: Effects and terminal replies

**Files:** Modify `src/vt.zig`.

**Interfaces:**
- Produces: `vt.Callbacks = struct { ctx: ?*anyopaque = null, write_pty: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null, bell: ?*const fn (ctx: ?*anyopaque) void = null, title_changed: ?*const fn (ctx: ?*anyopaque) void = null }`; `Options.callbacks: Callbacks = .{}`; `Terminal.title(self: *Terminal) []const u8` (valid until the next write).

- [ ] **Step 1: Write the failing tests** (a test context struct collects `replies: [64]u8` + length, `bells: u32`, `titles: u32`):

```zig
test "bell callback fires" { write("\x07") -> bells == 1 }
test "title change callback and getter" { write("\x1b]0;hello\x07") -> titles == 1 and t.title() == "hello" }
test "cursor position report goes to write_pty" {
    write("\x1b[6n") -> replies == "\x1b[1;1R"
    write("ab\x1b[6n") (fresh terminal) -> replies == "\x1b[1;3R"
}
```

- [ ] **Step 2: Run.** Expected: FAIL (`callbacks` not an option).
- [ ] **Step 3: Implement.** Set `OPT_USERDATA` to the `*Terminal`, and `OPT_WRITE_PTY`, `OPT_BELL`, `OPT_TITLE_CHANGED` to `callconv(.c)` trampolines that forward to `opts.callbacks` with `ctx`. The callbacks run inside `write`; document that they must not call `write`. Pass function pointers directly as the `value` argument of `ghostty_terminal_set` (see `example/c-vt-effects/src/main.c` in the Ghostty repository at tag `vt-1.0.1`). `title()` reads `GHOSTTY_TERMINAL_DATA_TITLE`.
- [ ] **Step 4: Run.** Expected: PASS. If the cursor report does not arrive, the test shows which option the library also needs (check `GHOSTTY_TERMINAL_OPT_SIZE` / device attributes in `terminal.h`) and the step is not done until it passes.
- [ ] **Step 5: Commit** `git add src/vt.zig && git commit -m "vt: bell, title and pty-reply callbacks"`

---

### Task 4: Scrollback, kitty limit, resize

**Files:** Modify `src/vt.zig`.

**Interfaces:**
- Produces: `Terminal.scrollbackRows(self: *Terminal) usize`; `Terminal.size(self: *Terminal) struct { cols: u16, rows: u16 }`; `Terminal.resize(self: *Terminal, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) void`.

- [ ] **Step 1: Write the failing tests**

```zig
test "default scrollback keeps about 1000 rows at 80 columns" {
    // 80x24, write "line N\r\n" for N in 0..3000
    const n = t.scrollbackRows();
    try std.testing.expect(n >= 1000 and n <= 1100); // spike measured 1,065
}
test "scrollback_bytes = 0 keeps nothing" { .{ .scrollback_bytes = 0 }, 100 lines -> scrollbackRows() == 0 }
test "kitty image storage limit is zero" { ghostty_terminal_get(t.handle, GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT, &limit); limit == 0 }
test "resize to 1x1 and 500x200 keeps working" {
    t.resize(500, 200, 0, 0); size() == {500,200}; write("x"); rowText(0) starts with "x"
    t.resize(1, 1, 0, 0); size() == {1,1}; write("hello\r\n") does not crash
}
```

- [ ] **Step 2: Run.** Expected: FAIL (methods missing).
- [ ] **Step 3: Implement** with `GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS` (`size_t`), `ghostty_terminal_resize`, `GHOSTTY_TERMINAL_DATA_COLS/ROWS`; in `init` set `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT` to 0 (check the option's value type in `terminal.h`).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `git add src/vt.zig && git commit -m "vt: scrollback rows, resize, kitty storage off"`

---

### Task 5: `Pty`

**Files:** Create `src/pty.zig` (replaces the empty stub); add `_ = @import("pty.zig");` to the `test {}` block in `src/capi.zig`.

**Interfaces:**
- Produces: `pty.SpawnOptions = struct { argv: []const [:0]const u8, cols: u16 = 80, rows: u16 = 24, cwd: ?[:0]const u8 = null }`;
  `Pty.spawn(gpa: std.mem.Allocator, opts: SpawnOptions) !Pty`; `Pty.spawnShell(gpa: std.mem.Allocator, cols: u16, rows: u16) !Pty` (login shell, cwd `$HOME`);
  `loginArgv0(buf: []u8, shell: []const u8) []const u8` (`"/bin/zsh"` gives `"-zsh"`);
  `read(self: *Pty, buf: []u8) !usize` (0 at end of output; EIO counts as end); `write(self: *Pty, bytes: []const u8) !void` (loops on partial writes);
  `resize(self: *Pty, cols: u16, rows: u16, px_w: u16, px_h: u16) !void` (`TIOCSWINSZ`); `wait(self: *Pty) u8` (exit code; `128 + signal` if signalled; cached); `kill(self: *Pty) void` (SIGHUP then reap); `deinit(self: *Pty) void`; fields `fd: c_int`, `pid: c_int`.

- [ ] **Step 1: Write the failing tests** (helper `readAll(p, gpa) ![]u8` reads to end):

```zig
test "child output arrives" { spawn {"/bin/sh","-c","printf hello"} -> readAll == "hello" }
test "exit code" { {"/bin/sh","-c","exit 3"} -> after readAll, wait() == 3 }
test "child environment" { sh -c 'printf "%s:%s:%s" "$TERM" "$COLORTERM" "$TERM_PROGRAM"' -> "xterm-256color:truecolor:Harf" }
test "resize reaches the child" { cols 80 rows 24; sh -c 'sleep 0.3; stty size'; resize(100, 30, 0, 0) immediately; readAll contains "30 100" }
test "login argv0" { loginArgv0(&buf, "/bin/zsh") == "-zsh" }
```

- [ ] **Step 2: Run.** Expected: FAIL (no `Pty`).
- [ ] **Step 3: Implement** with `extern "c"` declarations for `forkpty` (libSystem) and `ioctl`; `std.c.waitpid`, `execve`, `_exit`. Build `argv` and `envp` (parent environ plus `TERM`, `COLORTERM`, `TERM_PROGRAM`, `LANG` default) **before** forking; the child only does `chdir` (if `cwd`) and `execve`, then `_exit(127)`. Use `winsize` from `std.c` for the initial size.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `git add src/pty.zig src/capi.zig && git commit -m "pty: forkpty wrapper with resize, wait, kill"`

---

### Task 6: `Session` (PTY + grid + I/O thread)

**Files:** Create `src/term.zig`; add `_ = @import("term.zig");` to the `test {}` block in `src/capi.zig`.

**Interfaces:**
- Consumes: `vt.Terminal` (Tasks 1 to 4), `pty.Pty` (Task 5).
- Produces: `term.Callbacks = struct { ctx: ?*anyopaque = null, wake: ?*const fn (?*anyopaque) void = null, title: ?*const fn (?*anyopaque) void = null, bell: ?*const fn (?*anyopaque) void = null, exited: ?*const fn (?*anyopaque, status: u8) void = null }` (all invoked on the I/O thread);
  `term.Options = struct { cols: u16 = 80, rows: u16 = 24, scrollback_bytes: usize = 1 << 20, argv: ?[]const [:0]const u8 = null, callbacks: Callbacks = .{} }` (`argv == null` means login shell);
  `Session.start(gpa: std.mem.Allocator, opts: Options) !*Session`; `deinit(self: *Session) void`; `input(self: *Session, bytes: []const u8) !void`; `resize(self: *Session, cols: u16, rows: u16, px_w: u16, px_h: u16) !void`; `lock(self: *Session) *vt.Terminal`; `unlock(self: *Session) void`; `wakeHandled(self: *Session) void` (re-arms `wake`); `exitStatus(self: *Session) ?u8`; `pid(self: *Session) c_int`.
- Behavior: I/O thread loop is `read` (blocking) then lock, `Terminal.write`, unlock, then `wake` if not already pending (an atomic flag set before the call, cleared only by `wakeHandled`). Terminal replies (`write_pty`) are written to the PTY from inside that thread. On end of output: reap, store status, call `exited`. `deinit` while running: `kill`, join the thread, free everything.

- [ ] **Step 1: Write the failing tests** (test helper `waitFor(timeout_ms, predicate)` polls every 5 ms; test-only polling):

```zig
test "echo round trip" {
    // argv {"/bin/sh"}; input("echo hi\n"); waitFor some row of rows 0..23 equals "hi" (rowText under lock)
}
test "flood and fast exit" {
    // argv {"/bin/sh","-c","seq 1 200000"}; waitFor exitStatus() != null within 20 s; status == 0
    // the last non-blank row (rowText under lock) == "200000"; scrollbackRows() <= 1100
}
test "wake is coalesced until handled" {
    // argv {"/bin/sh"}, wake callback increments a counter.
    // input("echo a\n"); waitFor row "a" visible; count == 1 (never handled yet)
    // input("echo b\n"); waitFor row "b" visible; count == 1 still
    // wakeHandled(); input("echo c\n"); waitFor row "c" visible; count == 2
}
test "deinit kills a live child" {
    // argv {"/bin/sleep","60"}; const p = s.pid(); s.deinit(); std.posix.kill(p, @enumFromInt(0)) returns error.ProcessNotFound
}
test "resize while output streams" {
    // seq 1 200000; 50 times resize alternating (10,5) (200,60) (1,1); finishes with exit 0, no crash
}
test "exit status is reported" { sh -c 'exit 7' -> exited callback receives 7 and exitStatus() == 7 }
test "terminal replies reach the child" {
    // sh -c 'stty raw -echo; printf "\033[6n"; dd bs=1 count=6 2>/dev/null | od -An -tx1'
    // waitFor a row containing "1b 5b 31 3b 31 52"
}
```

- [ ] **Step 2: Run.** Expected: FAIL (no `Session`).
- [ ] **Step 3: Implement** `Session` with `std.Thread.spawn`/`join` and `std.c.pthread_mutex_*` (`lock`/`unlock`), `std.atomic.Value(bool)` for the wake flag, a `std.c` read buffer of 64 KiB, and the vt `write_pty` callback bound to `Pty.write` (replies must never call `Terminal.write`).
- [ ] **Step 4: Run** the suite, and run the session tests three times in a row to flush out races: `for i in 1 2 3; do .tools/zig/zig build test || break; done`. Expected: PASS each time.
- [ ] **Step 5: Commit** `git add src/term.zig src/capi.zig && git commit -m "term: Session joins pty, grid and I/O thread"`

---

### Task 7: C ABI, header, Swift link, docs

**Files:** Modify `src/capi.zig`, `include/harf.h`, `macos/Package.swift`, `ARCHITECTURE.md`.

**Interfaces:**
- Consumes: `term.Session`, `term.Options`, `term.Callbacks`.
- Produces (C, in `include/harf.h`, mirrored by `export fn` in `src/capi.zig`):

```c
typedef struct HarfTerm HarfTerm;
typedef struct {
    void *ctx;
    void (*wake)(void *ctx);
    void (*title)(void *ctx);
    void (*bell)(void *ctx);
    void (*exited)(void *ctx, int status);
} HarfTermCallbacks;
/* argv: NULL-terminated, or NULL for the login shell. Returns NULL on bad arguments or spawn failure. */
HarfTerm *harf_term_new(uint16_t cols, uint16_t rows, size_t scrollback_bytes,
                        const char *const *argv, const HarfTermCallbacks *cb);
void   harf_term_free(HarfTerm *t);
int    harf_term_input(HarfTerm *t, const uint8_t *bytes, size_t len);              /* 0 = ok */
int    harf_term_resize(HarfTerm *t, uint16_t cols, uint16_t rows, uint32_t cell_w_px, uint32_t cell_h_px);
size_t harf_term_row_text(HarfTerm *t, uint16_t row, char *out, size_t cap);        /* UTF-8, no NUL, returns full length */
void   harf_term_wake_handled(HarfTerm *t);
int    harf_term_exit_status(HarfTerm *t);                                          /* -1 while running */
```

- [ ] **Step 1: Write the failing tests** in `src/capi.zig`:

```zig
test "harf_term round trip through the C ABI" {
    // argv {"/bin/sh","-c","printf hi", null}; callbacks with an `exited` flag; wait (poll, 10 s) for exit_status() == 0
    // harf_term_row_text(t, 0, buf, buf.len) == 2 and buf[0..2] == "hi"; harf_term_free(t)
}
test "harf_term_new rejects zero size" { harf_term_new(0, 24, 1 << 20, null, &cb) == null }
```

- [ ] **Step 2: Run.** Expected: FAIL (exports missing).
- [ ] **Step 3: Implement** the exports (`export fn`, `callconv(.c)` trampolines that adapt `HarfTermCallbacks` to `term.Callbacks`; `HarfTerm` is an opaque pointer to a heap struct holding the `*Session` and the copied callbacks). Add the declarations above to `include/harf.h`.
- [ ] **Step 4: Run** `.tools/zig/zig build test`. Expected: PASS.
- [ ] **Step 5: Swift still links.** Add `.linkedLibrary("ghostty-vt-static")` to `macos/Package.swift` (confirm the archive name with `ls zig-out/lib`). Run `macos/build-app.sh`. Expected: builds. Then `nm -g zig-out/lib/libharf.a | grep -c harf_term_` is at least 7, and `open macos/.build/Harf.app` still shows the spike page (this slice changes no UI).
- [ ] **Step 6: Docs.** Add a row to the `ARCHITECTURE.md` decisions log: slice 1 done, `vt.zig`/`pty.zig`/`term.zig`, libghostty-vt 1.0.1 pinned with `simd=false`, 1 MiB scrollback default.
- [ ] **Step 7: Commit**

```bash
git add src/capi.zig include/harf.h macos/Package.swift ARCHITECTURE.md
git commit -m "capi: harf_term_* C ABI over Session; link libghostty-vt"
```

## Done when

`.tools/zig/zig build test` passes three runs in a row, `macos/build-app.sh` builds, and the Review Focus tests all exist and pass. Slice 2's plan is written after this lands.
