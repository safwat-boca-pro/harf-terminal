# Phase 3 design: PTY, VT parser and grid (LTR only)

Status: **draft for owner approval** (2026-11-13). Brief section 8, Phase 3. Nothing here is built yet.

## Intent

Harf has a renderer, a cell model (C fit) and a bidi algorithm (UAX #9), but no terminal: nothing runs a shell
or holds its output. Phase 3 builds that: a child shell on a PTY, a VT parser, and a grid of cells in **logical
order** that the window draws. Phase 4 then puts bidi and Arabic layout on top of that grid. The grid being
logical-order, with tashkeel inside its base cell, is what makes that layering possible (brief 4.2).

**Done when** (brief): a daily-usable plain terminal. Concretely: zsh runs; core `vttest` cases pass; vim, tmux,
htop, less and fzf work; the idle and memory budgets still hold; throughput and latency are recorded in `docs/perf.md`.

## Goals, non-goals, anti-goals

Goals
- A real shell session in the window: typing, paste, resize, colors and styles, cursor, title, bell, child exit.
- Scrollback (default **1 MiB**, owner decision), alternate screen, mouse reporting, focus events, bracketed paste.
- Idle cost stays zero: no polling, no timers while idle. Footprint at the 80x24-class window (700x420 pt) at most
  30 MB `phys_footprint` with the default scrollback.
- Everything the grid exposes stays logical-order, so Phase 4 needs no grid changes.

Non-goals (later phases)
- Bidi, shaping, Arabic layout: Phase 4. In Phase 3 Arabic cells draw one letter per cell, unjoined. That is expected and temporary.
- Agent-compatibility work beyond what the library gives for free (synchronized output, kitty keyboard flags, OSC 52, notifications): Phase 5.
- Tabs, splits, OSC 133 UI, status, search UI, config file: Phase 6. IME and Arabic-keyboard polish, bidi-aware selection: Phase 7.
- Kitty graphics. It is compiled into libghostty-vt; Phase 3 sets its image storage limit to zero.

Anti-goals (a failure even if it works)
- Any timer or wake-up while the terminal is idle.
- Swift seeing libghostty headers, or a second copy of the grid in memory.
- Changing a locked decision in the brief (section 2) without asking.

## Constraints

- Zig 0.17.1 pinned. libghostty-vt 1.0.x requires Zig 0.17.x (major.minor must match), so our Zig upgrades are now tied to Ghostty's.
- 30 MB `phys_footprint` target at 700x420 pt. The Phase 1 spike app already measures 28 MB there, so every MB counts.
- MIT project: dependencies must be MIT-compatible, and notices must ship (`NOTICE`).
- C ABI stays small, hand-written (`include/harf.h`); capability goes in Zig, not Swift.

## Approaches considered

**A. Reuse libghostty-vt 1.0.1 through its C API, behind a thin Zig wrapper (chosen).**
**B. Write our own parser and grid.** Months of edge cases (wide characters, reflow, alternate screen, modes) with no gain
for Arabic; the spike showed A already stores the grid in the shape we need. Kept only as the fallback if A fails in Phase 3.
**C. Hybrid (own parser, Ghostty's screen).** Needs Ghostty's internal Zig modules, which the stability promise does not cover. Rejected.

Choice A was already the standing plan (`ARCHITECTURE.md`, 2026-11-12) pending a spike. The spike, run 2026-11-13 from the
signed release tarball in a scratch directory, answered the open checks:

| Check | Result |
|---|---|
| Arabic rows | Cells in logical order, one per letter. Tashkeel is inside its base cell (`0645+064E+0651`), lam-alef is two cells, ZWNJ joins the cell before it (`06CC+200C`), emoji are a wide cell plus a spacer. |
| Throughput (M1, parse into grid only, 64 KiB writes) | 186 to 448 MB/s depending on workload. SIMD only helps Arabic text (285 vs 206 MB/s). |
| Memory | Bare 80x24 terminal: under 1 MB. Scrollback is capped in bytes and page-granular: 4 MiB limit cost about 3.9 MB. **1 MiB limit holds about 570 to 1,160 rows at 80 columns** (history is pruned a whole page at a time, so the count swings between those bounds), regardless of content in the spike; rows cost a fixed amount per cell, so a wider window holds fewer (about 215 to 450 at 200 columns). Corrected 2026-11-13 during slice 1: the first spike sample read 1,065, which was one point in that swing. |
| Licenses | All permissive. Manifest shipped in the tarball (`deps/libghostty-vt-third-party.json`): libghostty-vt MIT; uucode MIT and Unicode-3.0; wuffs Apache-2.0 or MIT; highway Apache-2.0 or BSD-3 and simdutf Apache-2.0 or MIT (SIMD only); aro MIT and Unicode-3.0 and translate_c MIT (build time). |
| API fit | Terminal, render state with per-row dirty tracking, cells with grapheme codepoints and styles, cursor, selection, key (kitty protocol), mouse, focus and paste encoders, reply and effect callbacks (pty write, title, bell, clipboard, notification, DA, XTVERSION), OSC 133 selection, search. No PTY. |

Caveats on the numbers: one machine (M1, macOS 27.0.1), parser into grid only, no drawing; process footprint deltas, not
absolute app numbers. Signature (minisign) not verified: the tool is not installed. The pinned Zig content hash is the integrity check.

## Decisions

Owner's
- Reuse libghostty-vt (confirmed after the spike). C API only; Swift never sees its headers.
- Default scrollback **1 MiB** (about 570 to 1,160 rows at 80 columns), a setting later.
- Everything else in the brief stands (grid in logical order, CPU-drawn, 30 MB `phys_footprint`).

My calls (please check)
1. Build libghostty-vt with `simd=false`: no C++ dependencies, smaller, and 186 to 448 MB/s anyway. Revisit with vtebench numbers.
2. Depend on the release tarball by URL and Zig hash (`libghostty-vt-1.0.1.tar.gz`, hash recorded by `zig fetch`).
3. Child gets `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Harf`, a UTF-8 `LANG` if unset, and is started as the user's login shell in `$HOME`. No custom terminfo in v1.
4. Steady, non-blinking cursor in Phase 3 (blink needs a timer; brief 3.2).
5. Include minimal copy (Cmd+C of a mouse selection, using the library's selection) and paste (Cmd+V, bracketed when asked) so the terminal is usable daily. Phase 7 replaces selection with the bidi-aware visual model.
6. Include the editor-style keys from the brief (section 5: Option+arrows, Option+Backspace, Cmd+arrows) in the Swift key mapping.
7. Retire the spike C ABI (`harf_spike_*`, `spike.zig`, `Scene.swift`) when the terminal view lands. Keep `src/shape/layout.zig` and its tests for Phase 4.

## Design

```
macOS shell (Swift)          Zig core                                   libghostty-vt (C API)
-------------------          --------                                   ---------------------
NSView: keys, paste,   -->   harf_term_*  (include/harf.h)
 mouse, resize, draw                |
                                    +-- src/vt.zig   thin wrapper ----> terminal, render state,
                                    |                                   key/mouse/paste encoders
                                    +-- src/pty.zig  forkpty, read thread, winsize
                                    +-- draw: damaged rows -> CGContext (CoreText runs)
```

- **Threads.** One I/O thread per terminal: blocking `read` on the PTY master, then lock, `ghostty_terminal_vt_write`, unlock. No
  timers. The library's reply callbacks (device attributes, XTVERSION, color queries) run inside `vt_write` on that thread and write
  to the master; they must not re-enter `vt_write`.
- **Wake-up.** After a batch, if no redraw is pending, the I/O thread sets an atomic flag and calls the shell's wake callback;
  the shell hops to the main thread and invalidates only the damaged row rectangles. Under heavy output, redraws are coalesced to
  the display rate with a one-shot timer that exists only while output is arriving. Idle: nothing runs.
- **Drawing.** On the main thread: lock, `ghostty_render_state_update`, copy what the draw needs for dirty rows, unlock, draw. Per
  row: background fills for runs of equal background, then glyph runs per style at exact cell positions (`col * cell_w`) so the
  grid never drifts. Fallback fonts for characters Menlo lacks are looked up per cell and cached. Phase 3 draws Arabic one cell at
  a time; Phase 4 swaps in the C fit layout for rows that contain RTL.
- **Input.** Swift forwards `NSEvent` data (keycode, modifiers, text) to Zig, which encodes it with the library's key encoder
  (synced with the terminal's modes: application cursor keys, kitty flags) and writes to the PTY. Mouse and focus events likewise.
  Typed text, including Arabic from an Arabic keyboard, arrives through `insertText`. Full IME is Phase 7.
- **Resize.** The view computes columns and rows from the cell size, then Zig calls `ghostty_terminal_resize` and sets the PTY
  window size (which delivers SIGWINCH). Reflow is the library's.
- **Child exit.** The read thread sees EOF, reports the exit status through a callback, and the shell closes the window.
- **C ABI sketch** (names indicative, the builder finalizes and keeps the header hand-written):
  `harf_term_new(cols, rows, scrollback_bytes, callbacks)`, `_free`, `_spawn`, `_resize`, `_key`, `_text`, `_paste`, `_mouse`,
  `_focus`, `_scroll`, `_draw(ctx, dirty_rect)`, `_take_damage`, `_selection_text`; callbacks: wake, title, bell, exited.

## Slices (each ends green, with its own commit)

1. **Headless core.** Dependency in `build.zig.zon`, `src/vt.zig`, `src/pty.zig`, `harf_term_*` without UI. Tests: wrapper tests that
   feed sequences and assert cells (including the Arabic facts above as regressions); a PTY round trip that spawns `/bin/sh`, sends
   `echo hi`, and reads it back from the grid. `NOTICE` updated for what is actually linked.
2. **Window.** Terminal view replaces the spike view: draw grid and cursor, keyboard, paste, resize, title, bell, exit. zsh usable.
3. **Daily use.** Colors and styles (16, 256, truecolor, bold, italic, underline, inverse), scrollback viewport (wheel and
   trackpad), alternate screen, mouse reporting, focus events, minimal copy, editor-style keys.
4. **Conformance and numbers.** `vttest` core cases, vim, tmux, htop, less, fzf; vtebench throughput and a keypress-to-pixel
   latency measurement in `docs/perf.md`; footprint at 700x420 pt with 1 MiB scrollback. Investigate the extra `IOSurface`
   seen in the spike app (9.2 MB versus 5 MB in the throwaway prototype) if the footprint is over target.

## Risks

- **Memory budget:** only about 2 MB of headroom before the grid, scrollback (about 0.8 to 1 MB at the default) and real drawing state. The
  slice 4 measurement decides; if it fails, the options are a smaller default scrollback or revisiting the target (owner call).
- **Zig coupling:** our Zig version cannot move past Ghostty's. Acceptable; revisit if it blocks us.
- **Young dependency:** libghostty-vt is 1.0.1. The fallback (approach B) stays open until slice 4 passes.
- **Lock contention:** drawing holds the terminal lock only to copy row data; if latency suffers, move to a double-buffered snapshot.
- **vttest is interactive:** results are recorded as a checklist with screenshots for you to review, not an automated pass.
- **Dev tools:** vtebench (needs a Rust toolchain to build) and vttest are measurement tools, not project dependencies; they stay out of the repo and the build.

## Left to the builder

File and function names beyond those above; the redraw throttle interval; the font fallback cache; how Swift packages key events;
exact draw batching; whether to use the library's Zig module for tests (C API remains the product boundary).
