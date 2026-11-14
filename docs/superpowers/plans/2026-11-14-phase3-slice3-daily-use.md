# Phase 3, Slice 3: Daily Use Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harf becomes comfortable to live in: colors and text styles, scrollback you can scroll, full-screen programs that work with the mouse and the alternate screen, focus-aware cursor, and select-and-copy. Arabic rows (Phase 4) keep working with all of it.

**Architecture:** Zig does the work; Swift forwards `NSEvent` data. `vt.zig` grows style, color, viewport, mouse, focus and selection access over libghostty-vt's C API. `Painter` replaces its fixed theme with per-cell colors and styles on both the plain path and the shaped-Arabic path. New C ABI calls (`harf_term_scroll`, `_mouse`, `_focus`, `_selection_text`, `_clear_selection`) take pixel positions in device pixels; the core resolves them to cells through the painter's layout, so a click on a shaped Arabic row lands on the letter you see.

**Tech Stack:** Zig 0.17.1, libghostty-vt 1.0.1 (render state styles and colors, `ghostty_terminal_scroll_viewport`, mouse encoder, `ghostty_focus_encode`, selection gestures, formatter), CoreText/CoreGraphics, Swift 6 / AppKit.

**Spec:** `docs/superpowers/specs/2026-11-13-phase3-terminal-core-design.md` (slice 3: "Colors and styles (16, 256, truecolor, bold, italic, underline, inverse), scrollback viewport (wheel and trackpad), alternate screen, mouse reporting, focus events, minimal copy, editor-style keys"); `PROJECT_BRIEF.md` 4.2 (mouse hit-testing and copy go through the logical/visual map) and 5. Editor-style keys were already done in slice 2 and Phase 4 (Option/Command combinations, kitty-aware); not repeated here. Earlier plans: `docs/superpowers/plans/2026-11-13-phase3-slice2-window.md`, `docs/superpowers/plans/2026-11-14-phase4-arabic-rows.md`.

## Global Constraints

- Zig **0.17.1** pinned; no `@cImport`; libghostty types come through the `ghostty_c` module; CoreText bindings in `src/shape/ct.zig`. Tests: `.tools/zig/zig build test --summary all`; filter with `-Dtest-filter=<text>`.
- `include/harf.h` stays hand-written and in sync with `src/capi.zig`. Swift never sees libghostty headers.
- Idle cost zero: no timers or polling in product code. Consequence: no selection autoscroll while dragging outside the window (it needs a timer). Mouse-moved events only cost a C call and are dropped unless a program asked for them.
- 30 MB `phys_footprint` at 700x420 pt (measured in slice 4): every cache keeps a hard cap and a test that shows it (glyph cache stays at 4096 entries, now keyed by codepoint and face; fallback fonts stay at 64 across all faces).
- Grid and copy stay logical-order. Copied text is the library's text for the logical cell range; no visual reordering (that is Phase 7).
- Draw path performance: the Phase 4 numbers (cold 24-row Arabic screen about 15 ms, cached about 2 ms) must not regress by more than 2x; Task 7 re-measures.
- No attribution trailers in commits (user's global rule).

## Decisions (my calls, please check)

1. **Default colors.** Harf's current theme (background 0.06/0.06/0.07, foreground 0.92) becomes the terminal's default foreground and background, set when the terminal is created, so OSC 10/11 queries answer with it. The 16 ANSI colors and the 256-color cube use the library's default palette. The painter reads colors from the render state on every draw, so a program's OSC 4/10/11 changes show.
2. **Bold is a bold face, not brighter colors.** Menlo Bold, Italic and Bold Italic via CoreText symbolic traits. Faint is the foreground blended 50% toward the background. Invisible cells draw no glyph. Inverse swaps foreground and background (default colors included).
3. **Shaped Arabic rows** honor background, foreground, inverse, faint, underline and strikethrough per cell. They ignore bold and italic (regular face); the layouter shapes a row with one font. Cost if wrong: bold Latin words on a row that also has Arabic show regular weight.
4. **Underline styles:** single, double, curly, dotted and dashed are drawn with plain CoreGraphics strokes at the baseline offset; underline color is honored. Overline is ignored.
5. **Wheel routing, in order:** (a) a program with mouse tracking on gets wheel button events; (b) on the alternate screen without tracking, three Up or Down arrow key presses per notch (the "alternate scroll" behavior of other terminals); (c) otherwise the viewport scrolls, three rows per wheel notch, and trackpad point deltas accumulate in Swift and convert at the cell height.
6. **Any key, paste or text input snaps the viewport to the bottom.** New output while scrolled up does not move the viewport; the cursor is hidden while scrolled.
7. **Mouse tracking vs selection:** while a program has mouse tracking on, clicks and drags go to it; holding Shift selects text instead (xterm convention). With tracking off, a drag selects.
8. **Hit-testing:** a pixel is resolved to a cell by the painter: through `RowLayout` spans on shaped rows, `x / cell_w` on plain rows, clamped to the grid. Programs are told the cell's center, so the library's own cell math agrees with the resolved cell.
9. **Selection and copy.** The library's selection gestures give cell, word (double click) and line (triple click) selection. Cmd+C copies the library's formatted text of the selection (logical order) to the pasteboard; Cmd+C with no selection does nothing. Fixed selection color (0.22, 0.33, 0.55). No copy-on-select, no rectangle selection, no Cmd+A, no autoscroll. Output that changes the selected text clears the selection (the library decides; the test pins it).
10. **Cursor.** Honors the program's cursor shape (block, bar, underline) and cursor color; steady, not blinking (slice 3 keeps the no-timer rule). Unfocused window: hollow block. Focus-in and focus-out are sent to the program only when it enabled focus events.

## Review Focus

Inputs the spec implies but a straightforward test would miss; each is pinned by a test in the named task.

1. A click, drag or copy on a shaped Arabic row lands on the cell drawn under the pointer, including the second cell of lam-alef, a tashkeel base, and the blank cells after the text (Task 6 `hit test on a shaped row`, `selection copy is logical text`).
2. Scrolling: a wheel flood clamps at the top and bottom of the scrollback and keeps the cursor row intact; typing while scrolled up snaps to the bottom and the typed character is on screen (Task 3 `viewport clamps`, `input snaps to bottom`).
3. Mouse positions outside the grid (drag past the window edge, negative coordinates) clamp to the grid, and a grid wider than 223 columns still reports correctly in SGR mode and does not corrupt X10 reports (Task 4 `mouse positions clamp`, `wide grid`).
4. Colors: a blank cell erased with a background color is painted; a wide character's spacer cell takes the wide cell's background; inverse plus selection plus cursor on one cell stays legible (Task 2 `erased cells keep their background`, `wide cell background`, `cursor on selected inverse cell`).
5. Copying text with Arabic, tashkeel, combining marks, wide characters and soft-wrapped lines returns exactly the logical text, with no trailing blanks per row and no break at a soft wrap (Task 6 `selection copy is logical text`).

---

### Task 1: Styles and colors from the library

**Files:**
- Modify: `src/vt.zig`, `src/draw.zig` (only the `Cell` consumers' field access if needed)

**Interfaces:**
- Consumes: `vt.Terminal` render state (`update`, `selectRow`, `cellInRow`); libghostty row cell data for style, resolved foreground and background colors, and the render state colors (default foreground, background, cursor, palette).
- Produces:
  - `pub const Rgb = struct { r: u8, g: u8, b: u8 };`
  - `pub const Style = struct { fg: ?Rgb = null, bg: ?Rgb = null, underline_color: ?Rgb = null, flags: u16 = 0 }` with `pub const Flag = struct { bold, italic, faint, blink, inverse, invisible, strikethrough, overline: u16 }` (the library's bit values) and `pub fn underline(self: Style) Underline` where `pub const Underline = enum { none, single, double, curly, dotted, dashed }`.
  - `vt.Cell` gains `style: Style = .{}` (existing `cps`, `wide` unchanged; cells with no styling skip the per-cell style call).
  - `pub const Colors = struct { fg: Rgb, bg: Rgb, cursor: ?Rgb }` and `pub fn colors(self: *Terminal) Colors` (current defaults after the last `update`).
  - `Options` gains `default_fg: ?Rgb, default_bg: ?Rgb`, applied at `init` (Decision 1).

- [ ] **Step 1: Write the failing tests** in `src/vt.zig`:
  - `sgr colors resolve`: write `ESC[31mA` (palette red), `ESC[38;5;196mB` (256), `ESC[38;2;1;2;3mC` (truecolor), `ESC[48;2;9;8;7mD`; each cell's `style.fg`/`bg` is the expected `Rgb`; a plain cell has `fg == null`.
  - `style flags`: bold, italic, faint, inverse, invisible, strikethrough, and each underline style (`ESC[4:3m` curly, etc.) arrive in `style.flags` and `style.underline()`.
  - `default colors are Harf's`: `colors()` returns the theme set in `Options`; after `OSC 11 ; rgb:10/20/30 ST` the background changes accordingly.
  - `palette change shows`: `OSC 4 ; 1 ; rgb:ff/00/00 ST` then `ESC[31mx`: the cell's fg is `ff0000`.
  - `erased cell keeps its background`: `ESC[44m` then `ESC[2K` on a row: cells have `bg` blue and no codepoints.
- [ ] **Step 2: Run** `-Dtest-filter=sgr colors` etc. Expected: FAIL (fields missing).
- [ ] **Step 3: Implement** the types and the reads above in `vt.zig`. `Style` is filled only when the cell has styling.
- [ ] **Step 4: Run** the filters, then the whole suite. Expected: all pass.
- [ ] **Step 5: Commit** `vt: cell styles and terminal colors`.

---

### Task 2: Painter draws colors and styles

**Files:**
- Modify: `src/draw.zig`, `src/shape/ct.zig` (symbolic-trait font calls if missing)
- Test: `src/draw.zig`

**Interfaces:**
- Consumes: Task 1 (`Cell.style`, `Terminal.colors`), `rowlayout.RowLayout` spans, Phase 4 `Painter`.
- Produces:
  - `Painter.focused: bool = true` (pub field; capi sets it from the session in Task 5) and cursor shape/color from the render state (`vt.Cursor` gains `shape: enum { block, bar, underline, block_hollow }` and `color: ?Rgb`).
  - Face selection: `Painter` holds four faces (regular, bold, italic, bold italic) created from Menlo with symbolic traits; the glyph cache key becomes `(cp, face)`, still capped at 4096; fallback fonts for a face come from `CTFontCreateForString` on that face and stay within the 64-font cap.
  - Drawing order per row: backgrounds for runs of equal background (the spacer cell of a wide cell takes the wide cell's background), then glyphs, then underline and strikethrough lines. Inverse swaps colors; faint blends 50% toward the cell's background; invisible draws no glyph.
  - The shaped path (`drawShaped`) takes per-cell colors by `lcol`, draws backgrounds from `RowLayout.span`, and ignores bold/italic (Decision 3).
  - The cursor: block, bar (2 px wide), underline (2 px tall) or hollow block per shape; hollow block when `!focused`; the cursor color is the program's if set, else the foreground; the glyph under a solid block is redrawn in the background color as in slice 2.

- [ ] **Step 1: Write the failing pixel tests** with the existing `Canvas` harness:
  - `foreground and background colors`: `ESC[31;44mA` draws red ink on a blue cell; truecolor and 256-color likewise; a plain cell still uses the default theme.
  - `erased cells keep their background`: `ESC[41m ESC[2K` paints the whole row red.
  - `wide cell background`: a wide character on `ESC[42m` is green across both columns.
  - `inverse swaps`: inverse text on default colors has a foreground-colored cell with background-colored ink.
  - `faint and invisible`: faint ink is darker than normal ink on the same cell; invisible has no ink.
  - `bold has more ink`: `ESC[1mH` inks more pixels than `H`, and `ESC[3mH` differs from `H`.
  - `underline and strike`: each underline style draws pixels in the bottom rows of the cell and nothing above the baseline; strikethrough draws pixels mid-cell; underline color is honored.
  - `shaped row colors`: `ESC[31m` + an Arabic word draws red ink and a background-colored span for `ESC[44m`; bold is ignored there (same pixels as regular).
  - `cursor shapes`: `ESC[6 q` (bar) fills only 2 px at the cell's left; `ESC[4 q` underline fills the bottom rows; `focused = false` draws a hollow block (interior pixel is background); `cursor on selected inverse cell` stays legible (foreground and background differ at the cursor cell).
- [ ] **Step 2: Run** `-Dtest-filter=foreground and background` etc. Expected: FAIL.
- [ ] **Step 3: Implement** the Painter changes. Keep the plain path's per-cell loop; build the background runs before drawing glyphs.
- [ ] **Step 4: Run** the filters, then the whole suite and `Harf --selftest`. Expected: all pass, `selftest ok`; slice 2 and Phase 4 draw tests unchanged (their default-colored cells still draw as before).
- [ ] **Step 5: Commit** `draw: colors, text styles, cursor shapes`.

---

### Task 3: Scrollback viewport and alternate-screen wheel

**Files:**
- Modify: `src/vt.zig`, `src/term.zig`, `src/capi.zig`, `include/harf.h`, `macos/Sources/Harf/TerminalView.swift`

**Interfaces:**
- Consumes: `ghostty_terminal_scroll_viewport`, the scrollbar data (`GHOSTTY_TERMINAL_DATA_SCROLLBAR`), the active-screen data.
- Produces:
  - `vt.Terminal.scrollViewport(delta_rows: i32) void`, `scrollToBottom() void`, `pub fn viewport(self) struct { offset: usize, total: usize, rows: usize }`, `pub fn onAlternateScreen(self) bool`.
  - `Session.scroll(delta_rows: i32) !void`: routes per Decision 5 (mouse routing arrives in Task 4; this task handles alternate-screen arrows and the viewport). Key, text input and paste call `scrollToBottom` first (Decision 6).
  - `int harf_term_scroll(HarfTerm *t, int32_t delta_rows)` (positive = toward newer output) in `capi.zig` and `harf.h`.
  - Swift: `scrollWheel(with:)` converts `scrollingDeltaY` (precise or not) into whole rows with an accumulator and calls `harf_term_scroll`; no timers.

- [ ] **Step 1: Write the failing tests:**
  - `viewport scrolls into history`: print 60 lines on a 10-row terminal; after `scrollViewport(-5)` row 0 of the screen is five rows older; `scrollToBottom` restores it.
  - `viewport clamps`: `scrollViewport(-100000)` stops at the first scrollback row and `+100000` at the bottom; a repeated flood of 1,000 calls leaves `viewport()` consistent.
  - `cursor hidden while scrolled`: the render state reports no visible cursor row while scrolled up.
  - `input snaps to bottom`: with the viewport scrolled up, `Session.input("x")` and `Session.key` (an arrow key) leave `viewport().offset` at the bottom, and a typed character echoed by `cat` is on the visible screen.
  - `alternate screen wheel sends arrows`: a child that runs `printf '\033[?1049h'` then reads raw bytes: `Session.scroll(-1)` makes it receive three `ESC [ A` sequences (or `ESC O A` in application cursor mode).
  - `new output does not move a scrolled viewport`: output arriving while scrolled leaves `offset` unchanged.
- [ ] **Step 2: Run** the filters. Expected: FAIL.
- [ ] **Step 3: Implement** the wrappers, `Session.scroll`, the capi call and the Swift wheel handling.
- [ ] **Step 4: Run** the whole suite, `macos/build-app.sh` and `Harf --selftest`. Add a self-test step: a child prints 80 lines; a real wheel `NSEvent` scrolls the view so that row 0's text changes. Expected: `selftest ok`.
- [ ] **Step 5: Commit** `scrollback viewport, wheel, alternate-screen scroll`.

---

### Task 4: Mouse reporting and pixel hit-testing

**Files:**
- Modify: `src/draw.zig` (hit test), `src/vt.zig`, `src/term.zig`, `src/capi.zig`, `include/harf.h`, `macos/Sources/Harf/TerminalView.swift`

**Interfaces:**
- Consumes: the mouse encoder and event objects, the mouse-tracking mode and format from the terminal; Task 3's `Session.scroll`.
- Produces:
  - `Painter.cellAt(self, term: *vt.Terminal, x_px: f64, y_px: f64) struct { col: u16, row: u16 }`: clamps to the grid; shaped rows resolve through `RowLayout` spans (the column whose span contains `x`, nearest span if between), plain rows by `x / cell_w`.
  - `vt.Terminal.mouseTracking(self) bool` and `encodeMouse(self, action, button, mods, col, row, cell_w_px, cell_h_px, out: []u8) []const u8` (position given as the cell's center in pixels).
  - `Session.mouse(...) !bool` (true if sent to the program), and wheel routing (a): when tracking is on, `Session.scroll` sends wheel button events instead.
  - `int harf_term_mouse(HarfTerm *t, HarfPainter *p, int action, int button, uint32_t mods, double x_px, double y_px)`; return 1 if the program took it, 0 if the caller should treat it as a selection gesture (Decision 7: Shift forces 0).
  - Swift: `mouseDown/Up/Dragged/Moved`, `rightMouseDown`, `otherMouseDown` and a `NSTrackingArea` for `mouseMoved`; positions converted to device pixels relative to the grid origin.

- [ ] **Step 1: Write the failing tests:**
  - `mouse reports in SGR mode`: child enables `?1000h ?1006h` and reads raw bytes; `Session.mouse` press and release at a known cell arrive as `ESC [ < 0 ; col ; row M` and `m` with 1-based coordinates.
  - `mouse off is not sent`: with tracking off `Session.mouse` returns false and sends nothing.
  - `any-motion only when asked`: motion events are sent in mode `?1003h` and dropped in `?1000h`.
  - `shift selects`: with tracking on and Shift held, `harf_term_mouse` returns 0 and sends nothing.
  - `mouse positions clamp`: x or y negative or past the grid reports the nearest edge cell.
  - `wide grid`: on a 300-column terminal in SGR mode column 250 reports correctly; in X10 mode column 250 does not corrupt the sequence (it is clamped or dropped as the library does; the test pins the library's behavior).
  - `wheel goes to a tracking program`: with `?1000h`, `Session.scroll(-1)` sends button 64 press (wheel up) instead of scrolling.
  - `cell lookup on plain and shaped rows`: `cellAt` on a Latin row gives `x / cell_w`; on `مرحبا` the column under the second letter's span is returned; a point in the blank area past the text gives the plain column.
- [ ] **Step 2: Run** the filters. Expected: FAIL.
- [ ] **Step 3: Implement.** Encode positions at cell centers (Decision 8).
- [ ] **Step 4: Run** the whole suite, build and `Harf --selftest`. Add a self-test: a child enables SGR tracking and reads bytes; a real `mouseDown` at a known point arrives as the expected report. Expected: `selftest ok`.
- [ ] **Step 5: Commit** `mouse reporting and hit-testing`.

---

### Task 5: Focus events and the unfocused cursor

**Files:**
- Modify: `src/term.zig`, `src/capi.zig`, `include/harf.h`, `macos/Sources/Harf/TerminalView.swift`, `macos/Sources/Harf/App.swift`

**Interfaces:**
- Consumes: `ghostty_focus_encode`, the focus-event mode; Task 2's `Painter.focused`.
- Produces: `Session.setFocus(focused: bool) !void` (stores the flag, sends `ESC [ I` / `ESC [ O` only when the program enabled mode 1004), `Session.focused() bool`; `void harf_term_focus(HarfTerm *t, int focused)`; `harf_term_draw` sets `painter.focused` from the session before drawing; Swift calls it from `viewDidMoveToWindow` observers (`NSWindow.didBecomeKey`, `didResignKey`) and when the view moves to a window.

- [ ] **Step 1: Write the failing tests:** `focus events only when asked` (a child enabling `?1004h` receives `ESC [ O` then `ESC [ I`; without the mode nothing is sent), `focus flag drives the cursor` (after `setFocus(false)` a draw shows the hollow block, after `true` the solid block).
- [ ] **Step 2: Run** the filters. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole suite, build and `Harf --selftest`. Expected: pass, `selftest ok`.
- [ ] **Step 5: Commit** `focus events and unfocused cursor`.

---

### Task 6: Selection and copy

**Files:**
- Modify: `src/vt.zig`, `src/term.zig`, `src/draw.zig`, `src/capi.zig`, `include/harf.h`, `macos/Sources/Harf/TerminalView.swift`, `macos/Sources/Harf/App.swift`

**Interfaces:**
- Consumes: the library's selection gesture objects, `ghostty_formatter` with a selection, the row selection range (`ROW_DATA_SELECTION` / `ROW_CELLS_DATA_SELECTED`), Task 4's `cellAt`.
- Produces:
  - `vt.Terminal.selectionPress(col, row, click_count, mods)`, `selectionDrag(col, row)`, `selectionRelease()`, `clearSelection()`, `hasSelection() bool`, `selectionText(gpa) ![]u8` (UTF-8, logical order).
  - Painter draws the selection: per selected cell the fixed selection background (Decision 9) with the cell's foreground kept; on shaped rows the highlight uses `RowLayout.span`; plain and shaped rows agree on which cells are selected.
  - `int harf_term_selection_event(HarfTerm *t, HarfPainter *p, int phase, int click_count, uint32_t mods, double x_px, double y_px)` (phase: press, drag, release), `char *harf_term_selection_text(HarfTerm *t, size_t *len)` (caller frees with `harf_free`), `void harf_term_clear_selection(HarfTerm *t)`, `void harf_free(void *p)`.
  - Swift: when `harf_term_mouse` returns 0, mouse down/drag/up go to the selection calls with `event.clickCount`; Cmd+C (menu item "Copy", action `copy:`) puts `selection_text` on `NSPasteboard`; clicking without dragging clears the selection.

- [ ] **Step 1: Write the failing tests:**
  - `selection copy is logical text`: for each of `hello world`, `مُحَمَّد` (tashkeel), `لا إله إلا الله` (lam-alef), `a\u{301}b` (combining mark), `日本語` (wide) and a row soft-wrapped across two rows, select all cells of the text with press and drag and read `selectionText`: it equals the original string exactly (no trailing blanks per row, no newline at the soft wrap, a hard newline between hard rows).
  - `word and line selection`: double click selects the word under the cell, triple click the line.
  - `selection draws on plain and shaped rows`: the selected cells have the selection background pixel; on `مرحبا` the highlighted pixels lie inside the spans of the selected columns.
  - `hit test on a shaped row`: press at the center of the second letter's span of `مرحبا` selects column 1; press past the text selects the plain column.
  - `output that changes the selection clears it`: after selecting, writing new text over the selected cells leaves `hasSelection()` false (pins what the library does; if the library keeps it, rule in the ledger and adjust Decision 9).
  - `selection survives scroll and is cleared by clear`: scrolling the viewport keeps the selection; `clearSelection` removes it.
- [ ] **Step 2: Run** the filters. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole suite, build and `Harf --selftest`. Add a self-test: print two lines, drive real mouse events across the first, copy through the controller, and check the pasteboard string. Expected: `selftest ok`.
- [ ] **Step 5: Commit** `selection and copy`.

---

### Task 7: End-to-end evidence, performance, owner checklist and docs

**Files:**
- Modify: `macos/Sources/Harf/main.swift`, `docs/perf.md`, `ARCHITECTURE.md`
- Create: `docs/slice3-manual-check.md`, `docs/slice3/` (pictures)

**Interfaces:**
- Consumes: everything above and the `HARF_SELFTEST_PNG_DIR` hook from Phase 4.
- Produces: a colored-output picture and an Arabic-with-colors picture for the owner, re-measured draw numbers, the checklist.

- [ ] **Step 1: Pictures.** With the PNG hook, render (a) a 16-color and 256-color ramp with bold, italic, underline styles and inverse (use `printf`), (b) `ls --color`-style output with Arabic file names in colors, (c) a selection over an Arabic row and a Latin row. Read each PNG yourself and note in the ledger what you see; do not claim they look right.
- [ ] **Step 2: Performance.** Extend the self-test's 1b measurement (a colored 80x24 Arabic screen, then a colored plain screen) and record cold and cached numbers, machine, date and build in `docs/perf.md`. If the Arabic cold draw exceeds 30 ms or cached exceeds 6 ms, say so in the ledger as a finding.
- [ ] **Step 3: Checklist** `docs/slice3-manual-check.md` for the owner: colors in `ls --color`, a color test script, `vim` with a colorscheme (and its mouse), `less` with the wheel, `htop` or `top` with the mouse, `tmux` with its mouse mode and `Shift`-drag to select, scrolling back through `seq 1 500` with the trackpad, typing while scrolled up, drag to select Arabic and Latin text and Cmd+C into another app, double and triple click, window focus in and out with the cursor changing (and with `printf '\033[?1004h'; cat -v` showing `^[[I` / `^[[O`), resize while scrolled.
- [ ] **Step 4: Docs.** `ARCHITECTURE.md` decision-log row for slice 3 (the ten decisions in one paragraph, what the new C ABI adds); `docs/slice2-manual-check.md` keeps its text.
- [ ] **Step 5: Run** the whole suite, `macos/build-app.sh`, `Harf --selftest`. Expected: all pass, `selftest ok`.
- [ ] **Step 6: Commit** `slice 3: end-to-end check, pictures, numbers, owner checklist`.

---

## Self-review

- Spec coverage (slice 3 line): colors and styles Tasks 1 and 2 (16, 256, truecolor, bold, italic, underline, inverse, plus faint, invisible, strikethrough); scrollback viewport (wheel and trackpad) Task 3; alternate screen Task 3 (wheel arrows; the library switches screens); mouse reporting Task 4; focus events Task 5; minimal copy Task 6; editor-style keys already done (Phase 4 follow-ups). The brief's 4.2 requirement (mouse hit-testing and copy through the logical/visual map) is Tasks 4 and 6.
- Not covered on purpose: selection autoscroll (needs a timer), rectangle selection, Cmd+A, copy-on-select, bold on shaped rows, overline, kitty graphics, OSC 8 links, OSC 52 clipboard, OSC 133 jumps (Phases 5 and 6); visual (bidi-aware) selection (Phase 7); the 30 MB measurement and vttest/vim/tmux conformance (slice 4).
- Types: `Rgb`, `Style`, `Cell.style`, `Colors`, `Painter.focused`, `Painter.cellAt`, the capi names and `Session` methods are named once in Interfaces and used with the same names in later tasks.
- Weak spots: Decision 9's claim about selection clearing on output is the library's behavior, pinned by a test that may force a ruling; Decision 5(b) and the three-row wheel step are conventions, not spec text.
