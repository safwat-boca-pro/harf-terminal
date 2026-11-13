# Phase 3, Slice 2: Terminal Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Harf.app` opens one window running the user's login shell: grid and cursor drawn, typing (including Arabic), paste, resize, title, bell and child exit all work. Plus the eight slice 1 loose ends the reviewer and I listed.

**Architecture:** Zig does everything with substance. New: a non-blocking input queue in `Session`, key and paste encoders (libghostty's) behind `harf_term_key` / `harf_term_paste`, and a `Painter` that draws rows and the cursor with CoreText, one cell at a time, no bidi. Swift gets one `TerminalView` that forwards events and hands a CGContext to `harf_term_draw`. The Phase 1 spike (`spike.zig`, `Scene.swift`, `harf_spike_*`) is retired.

**Tech Stack:** Zig 0.17.1, libghostty-vt 1.0.1 (C API), CoreText/CoreGraphics from Zig, Swift 6 / AppKit for the shell.

**Spec:** `docs/superpowers/specs/2026-11-13-phase3-terminal-core-design.md` (slice 2 of 4). Slice 1 plan: `docs/superpowers/plans/2026-11-13-phase3-slice1-headless-core.md`. Slice 1 deferred minors are in `.superpowers/sdd/2026-11-13-phase3-slice1-headless-core/progress.md` (`Final: minor (deferred)` lines); this plan folds all seven.

## Global Constraints

- Zig **0.17.1** pinned; no `@cImport`, no `std.Thread.Mutex`; use `std.c` pthread, extern declarations, and the `ghostty_c` module.
- Swift never sees libghostty headers; `include/harf.h` stays hand-written and in sync with `src/capi.zig`.
- Idle cost zero: no timers, no polling in product code (tests may poll with a timeout). The only teardown wait is the bounded one in `Pty.kill`.
- 30 MB `phys_footprint` at 700x420 pt (measured in slice 4; do not add caches that grow without bound: the glyph cache is keyed by codepoint and capped at 4096 entries).
- Grid stays logical-order. Phase 3 draws Arabic one letter per cell, unjoined, no reordering. That is expected and temporary.
- Steady, non-blinking block cursor. Default font Menlo 14 pt at the screen's scale; CoreText fallback for missing characters (font policy "left alone", no hardcoded Arabic font).
- Out of scope here (slice 3): colors and styles, scrollback viewport, mouse, focus events, copy, editor-style keys (Option+arrows etc.), alternate-screen niceties.
- No attribution trailers in commits (user's global rule). Tests run with `.tools/zig/zig build test --summary all`; filter with `-Dtest-filter=<text>`.

## Review Focus

Inputs the spec implies but a straightforward test would miss; each is pinned by a test in the named task.

1. Pasting megabytes while the child is not reading: no caller ever blocks (Task 2, `input never blocks`).
2. Closing a window whose shell ignores SIGHUP or has a background child: returns quickly, nothing left running (Task 3, `kill reaches the process group`, `kill escalates`).
3. Window shrunk below one cell, or resized repeatedly while output streams: grid stays at least 1x1, drawing never reads past it (Task 5, `draw clamps rows`; Task 7 self-test).
4. Arabic typed on an Arabic keyboard arrives at the child intact and is drawn (Task 4 `key with Arabic text`; Task 7 self-test).
5. The shell exits non-zero at once (bad `$SHELL`): the window stays and says so instead of vanishing (Task 7 self-test, `exit status 3 keeps the window`).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/vt.zig` | Wrapper fixes (title, >16 codepoints), explicit `update`/`selectRow`/`cursor`, key and paste encoders |
| `src/pty.zig` | Non-blocking `writeSome`, process-group kill, spawn lock, signal reset, chdir fallback |
| `src/term.zig` | Input queue serviced by the I/O thread; `Session.key`, `Session.paste`, `Session.title` |
| `src/keys.zig` (new) | macOS virtual keycode -> `GhosttyKey` table |
| `src/draw.zig` (new) | `Painter`: metrics, glyph cache with fallback, `drawRows`, cursor |
| `src/capi.zig`, `include/harf.h` | New exports; spike exports removed |
| `src/spike.zig`, `macos/Sources/Harf/Scene.swift` | Deleted (Task 6) |
| `macos/Sources/Harf/{main,TerminalView,App}.swift` | Window, view, menu, self-test |
| `ARCHITECTURE.md`, `docs/slice2-manual-check.md` (new) | Decision log row; the owner's hands-on checklist |

---

### Task 1: vt wrapper fixes and per-frame reads

Folds slice 1 minors: `title()` null pointer, cells over 16 codepoints, per-call `render_state_update`.

**Files:**
- Modify: `src/vt.zig`
- Test: `src/vt.zig`

**Interfaces:**
- Produces (all on `vt.Terminal`):
  `pub fn update(self: *Terminal) bool` (refresh the render state; false on failure);
  `pub fn selectRow(self: *Terminal, row: u16) bool` (now `pub`; does NOT call `update`);
  `pub fn cellInRow(self: *Terminal, col: u16, buf: *[16]u21) Cell` (the cell at `col` of the selected row; blank if out of range);
  `pub const Cursor = struct { col: u16, row: u16, visible: bool }`; `pub fn cursor(self: *Terminal) ?Cursor` (null when the cursor is outside the viewport; does NOT call `update`).
  `cell()` and `rowText()` keep their signatures and still call `update()` first.

- [ ] **Step 1: Write failing tests**
  - `title is empty when never set`: fresh terminal, `expectEqualStrings("", t.title())`.
  - `cell with more than 16 codepoints keeps the first 16`: write `a` + 20 x U+064E; `cell(0,0)` has `cps.len == 16` and `cps[0] == 'a'`.
  - `cursor follows output`: `write("ab\r\ncd")` then `update()`; `cursor()` is `{col=2,row=1,visible=true}`; after `write("\x1b[?25l")` and `update()`, `visible == false`.
  - `selectRow does not refresh`: `update()`, then `write("x")`, then `selectRow(0)` + `cellInRow(0)` is blank; after `update()` again it is `x`.
- [ ] **Step 2: Run** `-Dtest-filter=` each name. Expected: FAIL (compile errors for new functions; if the `title` test passes at once, ledger it: the unset case was not a crash on this machine, keep the guard and test anyway).
- [ ] **Step 3: Implement.** `title()`: return `""` when `str.len == 0` before slicing. `readCell`: when `GRAPHEMES_BUF` returns `GHOSTTY_OUT_OF_SPACE`, `gb.len` holds the real count; use `min(gb.len, 16)` (the header documents it; read `grapheme` section of `render.h`). Split `selectRow` into the iteration part (no update) and keep `cell`/`rowText` calling `update()` first. `cursor()` from `GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_{HAS_VALUE,X,Y}` and `CURSOR_VISIBLE`.
- [ ] **Step 4: Run** the full suite. Expected: all pass (48 existing + new).
- [ ] **Step 5: Commit** `vt: explicit update, cursor, >16 codepoint cells, empty title`

---

### Task 2: Non-blocking input queue

Folds the `Session.input` blocking gap and slice 1 minor "resize can block" (a size report from `resize` goes through the same write path).

**Files:**
- Modify: `src/pty.zig`, `src/term.zig`
- Test: `src/term.zig`, `src/pty.zig`

**Interfaces:**
- Consumes: `Pty` from slice 1.
- Produces: `Pty.writeSome(self: *Pty, bytes: []const u8) !usize` (one non-blocking `write`; returns 0 on `EAGAIN`). The master is `O_NONBLOCK` after `spawn`; `Pty.read` and `Pty.write` keep their blocking behaviour (they poll internally on `EAGAIN`), so slice 1 tests stay valid.
  `Session.input(self, bytes) !void` now only appends to a queue and returns; `error.InputQueueFull` when more than `max_pending_input = 64 << 20` bytes are queued. Terminal replies (`write_pty` callback) use the same queue, so order is preserved. The I/O thread polls `POLLOUT` on the master only while the queue is non-empty and drains it with `writeSome`.

- [ ] **Step 1: Write failing tests** (in `src/term.zig`)
  - `input never blocks`: argv `/bin/sh -c 'sleep 3'`; `input` of 8 MiB returns in under 200 ms (measure with a monotonic clock) and returns `{}`; then `deinit` is clean.
  - `queued input reaches the child in order`: argv `/bin/sh -c 'stty raw -echo; sleep 1; head -c 1000000 | wc -c'`; `input` 1,000,000 bytes immediately; wait for row text to contain `1000000`.
  - `resize with size reports does not block`: argv `/bin/sh -c 'printf "\033[?2048h"; sleep 3'`; fill the queue with 4 MiB via `input`; `resize(100, 30, 8, 16)` returns in under 500 ms.
  - `input over the cap is refused`: 65 MiB returns `error.InputQueueFull` and queues nothing.
- [ ] **Step 2: Run** `-Dtest-filter=input`. Expected: FAIL (first test takes seconds or times out in the runner).
- [ ] **Step 3: Implement** the queue (`std.ArrayList(u8)` under its own mutex, taken after `term_lock` never before; the I/O thread adds `POLLOUT` interest while non-empty). `onWritePty` appends instead of calling `pty.write`. Keep `write_lock` only if still needed; remove it if the queue mutex replaces it.
- [ ] **Step 4: Run** full suite. Expected: all pass, no leftover children (`ps` check as in slice 1).
- [ ] **Step 5: Commit** `term: non-blocking input queue; pty: writeSome`

---

### Task 3: Pty hardening

Folds slice 1 minors: kill stall, `FD_CLOEXEC` race, `chdir` failure, signal state inherited by the child.

**Files:**
- Modify: `src/pty.zig`
- Test: `src/pty.zig`

**Interfaces:**
- Produces (behaviour, no new public names): `Pty.kill` sends SIGHUP to the process group (`killpg(pid, ...)`), waits at most 100 ms, then SIGKILL to the group, then reaps. `Pty.spawn` holds a process-wide lock from `forkpty` until `setCloexec(master)` returns. In the child: `chdir` failure falls back to `/`; every catchable signal is reset to `SIG_DFL` and the signal mask is cleared before `execve` (async-signal-safe calls only; the existing rule).

- [ ] **Step 1: Write failing tests**
  - `kill escalates`: argv `/bin/sh -c 'trap "" HUP; sleep 60'`; `Pty.deinit()` returns in under 500 ms and `waitpid(pid)` afterwards says ECHILD (reaped).
  - `kill reaches the process group`: argv `/bin/sh -c 'sleep 60 & echo $! ; wait'`; read the printed pid; after `deinit`, `kill(pid, 0)` fails with ESRCH within 500 ms.
  - `concurrent spawns leak nothing`: 8 threads each spawn `/bin/sh -c 'ls /dev/fd | wc -l'`, read the number; all equal each other (the baseline is whatever one sequential spawn prints). Note: this may pass before the fix (race is narrow); if it does, ledger "guard test, not RED" and keep it.
  - `bad cwd falls back to /`: `spawn(.{ .argv = /bin/sh -c pwd, .cwd = "/nonexistent-harf" })` prints `/`.
  - `signal state is reset in the child`: the test thread calls `signal(SIGPIPE, SIG_IGN)` and blocks SIGUSR1 (`pthread_sigmask`); child runs `/bin/sh -c 'ps -o ignored=,blocked= -p $$'`; both masks read `0` (verify these `ps` keywords exist on this macOS; if not, use `sigmask`/`ignored` equivalents from `man ps`). Restore the test thread's state afterwards.
- [ ] **Step 2: Run** `-Dtest-filter=` each. Expected: `kill escalates` and `signal state` FAIL; `process group` FAILS (grandchild survives); `bad cwd` FAILS (prints the app's cwd).
- [ ] **Step 3: Implement** as described. Constants: grace 100 ms (the one polling loop, teardown only). Spawn lock is a `std.c.pthread_mutex_t` global.
- [ ] **Step 4: Run** full suite. Expected: all pass.
- [ ] **Step 5: Commit** `pty: group kill with 100 ms grace, spawn lock, signal reset, cwd fallback`

---

### Task 4: Keys and paste

**Files:**
- Create: `src/keys.zig`
- Modify: `src/vt.zig`, `src/term.zig`, `src/capi.zig`, `include/harf.h`
- Test: `src/keys.zig`, `src/vt.zig`, `src/capi.zig`

**Interfaces:**
- Consumes: `Session.input` (Task 2); `vt.Terminal` (Task 1).
- Produces:
  `keys.fromMac(keycode: u16) ?c.GhosttyKey` (macOS virtual keycodes: ANSI letters, digits, punctuation, Return 36, Tab 48, Space 49, Backspace 51, Escape 53, ForwardDelete 117, Home 115, End 119, PageUp 116, PageDown 121, arrows 123/124/125/126 = left/right/down/up, F1..F12 = 122,120,99,118,96,97,98,100,101,109,103,111). Null for unknown and for modifier keycodes.
  `pub const Mods = struct { pub const shift = 1; pub const ctrl = 2; pub const alt = 4; pub const super = 8; }` (our own bits, mirrored in `harf.h` as `HARF_MOD_*`).
  `vt.Terminal.encodeKey(self, key: c.GhosttyKey, mods: u32, utf8: []const u8, action: KeyAction, out: []u8) []const u8` and `vt.Terminal.encodePaste(self, text: []const u8, out: *std.ArrayList(u8), gpa) !void`, both synced to the terminal's current modes (application cursor keys, bracketed paste, kitty flags).
  `Session.key(self, keycode: u16, mods: u32, utf8: []const u8, action: KeyAction) !bool` (true = handled and queued, false = not handled: caller should use the text path) and `Session.paste(self, text: []const u8) !void`; `pub const KeyAction = enum(u8) { press = 0, release = 1, repeat = 2 }`.
  C ABI: `int harf_term_key(HarfTerm*, uint16_t keycode, uint32_t mods, const uint8_t *utf8, size_t len, int action)` returns 1 handled, 0 not handled, -1 error; `int harf_term_paste(HarfTerm*, const uint8_t *utf8, size_t len)` returns 0 or -1.
  Rule for "handled": a known key, or any key with ctrl or alt set; modifier-only keycodes are handled with nothing sent. Unknown keys with no ctrl/alt return false so Swift can run `interpretKeyEvents` (that is how Arabic layouts, dead keys and Option-compose reach the child, through `harf_term_input`).

- [ ] **Step 1: Write failing tests**
  - `keys.fromMac`: 126 -> arrow up, 36 -> enter, 8 -> `c`, 55/56/59 (Cmd/Shift/Ctrl) -> null.
  - `up arrow, normal and application mode` (vt level): `ESC [ A`; after `write("\x1b[?1h")` it is `ESC O A`.
  - `ctrl c is 0x03`; `enter is CR`; `backspace is DEL (0x7f)`; `shift tab is ESC [ Z`.
  - `key with Arabic text`: unknown keycode, no mods, utf8 `م` -> `Session.key` returns false (text path); then `input("م")` reaches a `cat -v`-like child as `M-bM-^E...` bytes (assert via `od` as in slice 1 replies test) i.e. the 2 UTF-8 bytes `d9 85`.
  - `paste plain`: `a\nb` becomes `a\rb`; `paste bracketed` after `write("\x1b[?2004h")` is `ESC[200~a\rb ESC[201~` (no spaces); paste containing `ESC[201~` has the ESC stripped (the library's safe-paste behaviour: read `paste.h`; assert what it actually does and ledger it).
  - C ABI: `harf_term_key` on a running `cat` session with up arrow returns 1; modifier-only returns 1; unknown key no mods returns 0.
- [ ] **Step 2: Run** `-Dtest-filter=key` and `paste`. Expected: FAIL (not defined).
- [ ] **Step 3: Implement.** Encoder lives in `vt.Terminal` (created in `init`, freed in `deinit`, `ghostty_key_encoder_set_from_terminal` before each encode). Release events encode to nothing unless kitty flags ask (library decides). `Session.key` locks the terminal, encodes, unlocks, then `input`s the bytes.
- [ ] **Step 4: Run** full suite. Expected: all pass.
- [ ] **Step 5: Commit** `keys, vt, term, capi: key and paste encoding through libghostty`

---

### Task 5: Painter

**Files:**
- Create: `src/draw.zig`
- Modify: `src/term.zig` (`Session.title`), `src/capi.zig`, `include/harf.h`, `build.zig` only if a new file needs wiring
- Test: `src/draw.zig`, `src/capi.zig`

**Interfaces:**
- Consumes: `vt.Terminal.update/selectRow/cellInRow/cursor` (Task 1), `shape/ct.zig`.
- Produces:
  `draw.Metrics = struct { cell_w: f32, cell_h: f32, ascent: f32 }`;
  `draw.Painter.init(gpa, size_px: f32) !*Painter`, `deinit`, `metrics(self) Metrics` (same formulas as the spike: width = round advance of `M` in Menlo, height = ceil ascent + ceil descent + ceil leading);
  `draw.Painter.drawRows(self, term: *vt.Terminal, ctx: *ct.CGContext, first_row: u16, last_row: u16) void` (caller holds the session lock; draws into a y-down device-pixel context whose origin is the grid's top-left; fills each row's background, draws every non-blank cell's codepoints at `col * cell_w`, then the cursor; rows beyond the grid are skipped; calls `term.update()` once).
  Theme (slice 3 replaces it): background `(0.06, 0.06, 0.07)`, foreground `(0.92, 0.92, 0.92)`, cursor is a filled block in the foreground color with the glyph under it redrawn in the background color.
  `Painter.lookup(self, cp: u21) ?Glyph` where `Glyph = struct { font: *const ct.CTFont, gid: u16 }`: Menlo first, else `CTFontCreateForString` fallback, cached by codepoint (cap 4096; when full, stop caching, keep working).
  C ABI: `HarfPainter *harf_painter_new(float size_px)`, `harf_painter_free`, `void harf_painter_metrics(HarfPainter*, HarfCellMetrics *out)`, `void harf_term_draw(HarfTerm*, HarfPainter*, void *cg_context, uint16_t first_row, uint16_t last_row)` (takes the session lock itself), `size_t harf_term_title(HarfTerm*, char *out, size_t cap)`.
  `Session.title(self, out: []u8) []const u8` copies under the lock (answers "valid only until next write").

- [ ] **Step 1: Write failing tests** (pixel tests render into `ct.CGBitmapContextCreate` 8-bit RGBA, flipped to y-down like the spike's `dump`)
  - `metrics are positive and cell_w is whole pixels` at 28 px.
  - `lookup: ascii is Menlo, arabic is a fallback`: `lookup('a').font` is the primary; `lookup(0x0645)` is non-null, `gid != 0`, different font; second call returns the same font pointer.
  - `draw: text inks its cells only`: 20x3 terminal, write `abc`; draw rows 0..2; pixels inside cells 0..2 of row 0 differ from background, pixels in cells 5..19 of row 0 and all of row 1 equal the background.
  - `draw: cursor block`: cursor at col 3 row 0: the cell box is foreground-colored at its corner pixel; after `\x1b[?25l` it is background.
  - `draw: arabic cell inks its cell`: write `مرحبا`; cells 0..4 have ink; tashkeel cell (`مَ`) draws without crash.
  - `draw clamps rows`: 10x2 terminal, `drawRows(first=0,last=500)` does not crash; a 1x1 terminal draws; shrinking a 40x10 terminal to 3x1 then drawing rows 0..9 does not crash.
  - `title copy`: `write("\x1b]0;hi\x07")`, `Session.title` returns `hi`; capped `cap=1` returns `h`.
- [ ] **Step 2: Run** `-Dtest-filter=draw`. Expected: FAIL (not defined).
- [ ] **Step 3: Implement** the Painter. One `CTFontDrawGlyphs` call per cell is fine here (slice 4 measures; do not batch yet). Clip to the grid rectangle once per `drawRows` so wide fallback glyphs cannot spill outside the window. Non-BMP codepoints: encode to UTF-16 for CoreText, draw the glyphs CoreText returns.
- [ ] **Step 4: Run** full suite. Expected: all pass.
- [ ] **Step 5: Commit** `draw: Painter draws rows and cursor; harf_term_draw`

---

### Task 6: Retire the spike; `TerminalView` draws a live session

**Files:**
- Delete: `src/spike.zig`, `macos/Sources/Harf/Scene.swift`
- Modify: `src/capi.zig` (remove `harf_spike_*`), `include/harf.h` (remove spike types), `macos/Sources/Harf/main.swift`
- Create: `macos/Sources/Harf/TerminalView.swift`, `macos/Sources/Harf/App.swift`
- Test: `Harf --selftest` (below), `zig build test`

**Interfaces:**
- Consumes: `harf_term_new/free/resize/draw/wake_handled/exit_status/title`, `harf_painter_*` (Tasks 2 to 5).
- Produces (Swift): `final class TerminalController` owning `HarfTerm*`, `HarfPainter*` and the `TerminalView`; `TerminalView: NSView` (`isFlipped = true`, `acceptsFirstResponder = true`); `controller.start(argv: [String]?)`; `controller.gridSize: (cols: Int, rows: Int)`; `Harf --selftest` exits 0 on success, prints the failing check otherwise. The `HARF_CONTENT_SIZE=WxH` hook stays (docs/perf.md).
  Behaviours: font 14 pt at `window.backingScaleFactor` (size_px = 14 * scale; the context is scaled by `1 / scale` like the spike); inset 6 pt; `cols = max(1, floor((w - 2*inset) / cell_w_pt))`, same for rows; on `viewDidEndLiveResize` and `setFrameSize` call `harf_term_resize` only when cols or rows changed; `wake` callback (I/O thread) does `DispatchQueue.main.async { harf_term_wake_handled(t); needsDisplay = true }` and nothing else; `draw(_:)` converts `dirtyRect` to a row range and calls `harf_term_draw`; no timers.
  Ordering rule: the controller calls `harf_term_free` before it releases anything the callbacks point at; callbacks hold an `Unmanaged` pointer and never run after `free` returns.

- [ ] **Step 1: Write the self-test first** in `main.swift`: `--selftest` creates a `TerminalController` with argv `/bin/sh -c 'printf "hello مرحبا"; sleep 2'` and no window; pumps the run loop up to 5 s until `harf_term_row_text(row 0)` contains `hello مرحبا`; renders the view offscreen with `bitmapImageRepForCachingDisplay` + `cacheDisplay` and checks that the first row has non-background pixels and the last row has none; resizes the controller to 1 x 1 pt and then 600 x 400 pt and checks `gridSize` is `(1,1)` then at least `(40, 10)` with no crash; calls `free`; prints `selftest ok`.
- [ ] **Step 2: Run** `macos/build-app.sh && macos/.build/Harf.app/Contents/MacOS/Harf --selftest`. Expected: build fails or self-test fails (no controller yet).
- [ ] **Step 3: Implement** the deletions, header edits, controller and view. Replace the AppDelegate with one that opens a 700x420 pt window titled `Harf`, starts the login shell, and quits after the last window closes (keep that existing behaviour).
- [ ] **Step 4: Run** the build and `--selftest`. Expected: `selftest ok`, exit 0. Run `.tools/zig/zig build test --summary all`. Expected: all pass (spike tests are gone; layout and bidi tests stay).
- [ ] **Step 5: Commit** `macos: TerminalView over harf_term_draw; retire the Phase 1 spike`

---

### Task 7: Keyboard, paste, title, bell, exit, menu; docs

**Files:**
- Modify: `macos/Sources/Harf/TerminalView.swift`, `App.swift`, `main.swift`, `ARCHITECTURE.md`
- Create: `docs/slice2-manual-check.md`
- Test: `Harf --selftest` (extended)

**Interfaces:**
- Consumes: `harf_term_key`, `harf_term_paste`, `harf_term_input`, title/bell/exited callbacks.
- Produces (Swift): `TerminalController.onTitle: (String) -> Void`, `onBell: () -> Void`, `onExit: (Int32) -> Void`; `TerminalView.keyDown(with:)`; main menu with Quit (Cmd+Q), Close (Cmd+W), Paste (Cmd+V).

- [ ] **Step 1: Extend the self-test first**
  - `typing round trip`: argv `/bin/sh -c 'read x; echo got:$x'`; send `a`, `م`, Return through the same code path the view uses (`view.simulateKey(...)` that builds the call the real `keyDown` makes: keycode, mods, characters); row text contains `got:aم`.
  - `paste`: argv `/bin/sh -c 'read x; echo got:$x'`; `controller.paste("x y")` then Return; row text contains `got:x y`.
  - `title and bell`: argv prints `\033]0;T1\007\007`; `onTitle` fired with `T1`, `onBell` fired once.
  - `exit status 3 keeps the window`: argv `/bin/sh -c 'echo boom; exit 3'`; `onExit(3)` fires; the controller's window is still open and its title contains `exited (3)`; row 0 reads `boom`. Exit status 0 closes the window.
- [ ] **Step 2: Run** the self-test. Expected: FAIL at `typing round trip` (no key path yet).
- [ ] **Step 3: Implement.** `keyDown`: Cmd held -> menu only (never sent). Otherwise call `harf_term_key(keycode, mods, characters, action)`; on 0, `interpretKeyEvents([event])` and implement a minimal `NSTextInputClient` whose `insertText` sends the UTF-8 with `harf_term_input` (no marked text yet: IME is Phase 7). Map `NSEvent.modifierFlags` to `HARF_MOD_*`. Paste reads `NSPasteboard.general` string. Title callback sets `window.title`; bell calls `NSSound.beep()`; exit status 0 closes the window, any other status keeps it with title `Harf (exited (N))`. Write `docs/slice2-manual-check.md`: a short checklist the owner runs by hand (zsh prompt appears; type `ls`; type and see Arabic; `echo مرحبا`; paste multi-line text; Ctrl+C stops `sleep 30`; arrows do history; resize by dragging; `exit` closes; `/usr/bin/false` as `$SHELL` keeps the window; Activity Monitor shows 0% CPU idle). Add the `ARCHITECTURE.md` decision-log row (slice 2: queue, group kill, spike retired, default font and inset).
- [ ] **Step 4: Run** `macos/build-app.sh && .../Harf --selftest`; full Zig suite. Expected: `selftest ok`; all tests pass. Then launch the app once, confirm it opens and stays idle (`ps -o %cpu`, 0.0 after 10 s).
- [ ] **Step 5: Commit** `macos: keys, paste, title, bell, exit; slice 2 manual check`

---

## Self-review notes

- Spec coverage (slice 2: "draw grid and cursor, keyboard, paste, resize, title, bell, exit"): draw Task 5/6, keyboard Tasks 4/7, paste 4/7, resize 6, title 5/7, bell 7, exit 7. Spike retirement (decision 7) Task 6. Editor-style keys (decision 6) and copy (decision 5) are slice 3 per the spec's own slice list.
- The seven folded minors: title null (T1), >16 codepoints (T1), per-call update (T1, now explicit and not relied on: this slice draws whole rows, no dirty flags; the row-dirty optimisation waits for slice 4 numbers), kill stall (T3), cloexec race (T3), chdir (T3), signal state (T3), resize blocking (T2). That is eight lines for seven reviewer minors; the eighth is the older `Session.input` blocking gap.
- Names checked across tasks: `update`, `selectRow`, `cellInRow`, `cursor` (T1) are what `drawRows` (T5) calls; `Session.input` (T2) is what `Session.key/paste` (T4) enqueue through; `harf_term_draw` / `harf_painter_*` (T5) are what T6 calls.
