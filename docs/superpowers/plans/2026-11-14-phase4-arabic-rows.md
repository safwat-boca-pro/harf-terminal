# Phase 4: Arabic Rows in the Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The window draws rows that contain Arabic the way an Arabic reader expects: joined letters, right-to-left word order, mirrored brackets, tashkeel and lam-alef correct, box-drawing rows untouched, and a cursor that lands on the right letter. Rows without RTL text keep the plain per-cell path and its speed.

**Architecture:** Zig only; the C ABI (`include/harf.h`) and the Swift shell do not change. The grid stays logical-order. For each visible row `Painter.drawRows` asks a new pure function (`rowfacts.analyze`) whether the row needs layout and which base direction it gets. Rows that do are turned into text, shaped by the existing Phase 1 `Layouter` (model D, "C fit": each Arabic word justified to exactly its cells), cached in a bounded row cache, and drawn glyph by glyph from the placed-glyph list. The same layout supplies a pixel box for every logical column, which is what the cursor uses. Our own UAX #9 (`src/bidi`) is used to cross-check CoreText's visual order in tests (the brief's golden-test requirement, 4.6); CoreText stays the shaper and the drawn order in this slice.

**Tech Stack:** Zig 0.17.1, CoreText/CoreGraphics from Zig, libghostty-vt 1.0.1 (via `vt.zig`), the existing `src/bidi/bidi.zig` and `src/shape/layout.zig`.

**Spec:** `PROJECT_BRIEF.md` sections 3.3, 4.1 to 4.7 and Phase 4 of section 8 (done when: "Arabic typed at a zsh prompt and Arabic command output look correct; boxes do not mirror"); `docs/cell-model.md` (model C fit, accepted by the owner in Phase 1); `docs/superpowers/specs/2026-11-13-phase3-terminal-core-design.md` (the logical-order grid). Slice 2 plan: `docs/superpowers/plans/2026-11-13-phase3-slice2-window.md`.

## Global Constraints

- Zig **0.17.1** pinned; no `@cImport`; CoreText bindings go in `src/shape/ct.zig`. Tests: `.tools/zig/zig build test --summary all`; filter with `-Dtest-filter=<text>`.
- `include/harf.h` and `src/capi.zig` signatures do not change. Swift does not change except `main.swift` self-test additions.
- The grid and copy stay logical-order (brief 4.2). Nothing in this phase reads layout geometry to decide what a cell contains.
- Fast path (brief 3.3): a row with no R, AL or explicit RTL control takes the existing per-cell path and calls no CoreText shaping. A test counts this.
- Idle cost zero: no timers, no polling. 30 MB `phys_footprint` at 700x420 pt: every cache has a hard cap and a test that shows it.
- Font policy stays "keep CoreText's cascade, no hardcoded Arabic font" (cell-model.md): the Arabic font passed to the layouter is the primary font (Menlo). Cost if the owner wants another face: one line in `Painter.init`.
- Cell width is Menlo's rounded "M" advance (`Painter.metrics`); layout uses that `cell_w`, so grid columns and layout columns agree.
- Theme is still the fixed slice 2 theme; colors and styles are slice 3's. Slice 3 and this phase both edit `src/draw.zig`; whichever lands second adapts.
- No attribution trailers in commits (user's global rule).

## Decisions (my calls, please check)

1. **Which rows need layout.** A row needs layout if any codepoint has bidi class R, AL, RLE, RLO, RLI or FSI. Rows with only Arabic-Indic digits (class AN) or only Latin take the plain path.
2. **Base direction, `auto`.** The row is RTL only if its first non-blank cell is itself a strong RTL character (R or AL) and the row has no box-drawing or block character (U+2500 to U+259F). Everything else is LTR. This is deliberately stricter than UAX #9 rule P2 (first strong): a zsh prompt like `➜  ~ الحمد` has Arabic as its first strong character, and P2 would flip the prompt to the right end of the line. Pure Arabic output lines (`السلام عليكم.`) are RTL, so their punctuation lands on the correct side. `ltr` and `rtl` overrides force the direction, including over the box rule. There is no config UI yet (Phase 6); the policy is a field on `Painter`.
3. **No OSC 133 use yet.** zsh does not emit it without shell integration (Phase 6). The input-region-as-its-own-paragraph idea from brief 4.5 waits for that.
4. **Cursor** is drawn on its logical cell: on a shaped row, the cell's pixel box from the layout; past the end of the text, at `col * cell_w`. This is what implicit-mode terminals do. While typing at an LTR row, an Arabic word grows leftward and the first letter drifts right (brief 4.5, cell-model.md). Task 6 produces a letter-by-letter picture so the owner can judge; any other cursor rule is a follow-up, not part of this plan.
5. **Left/Right inside Arabic stay logical.** They send the usual escape sequences; the shell moves by logical cell. Visual arrows and word-jump rules belong with the editor-style keys (Phase 7).
6. **Rows that cannot be mapped one cell per character take the plain path:** a wide cell (CJK, emoji), a spacer, or a cell whose later codepoints are not combining marks (for example a ZWJ emoji sequence). A final guard compares the layout's cell count with the row's; a mismatch also falls back. Cost if wrong: such a row shows unjoined Arabic, as in slice 2.
7. **Mirroring and ordering come from CoreText in this slice** (the Phase 2 note: layout used CoreText's bidi until Phase 4). Task 3 compares CoreText's order with our UAX #9 on the brief's sample strings. If they ever disagree, the disagreement is a finding to rule on, and switching the layouter to our levels becomes a later slice.
8. **Soft-wrapped rows are laid out one row at a time.** A long Arabic paragraph that wraps is reordered per screen row, not per paragraph. Cost if wrong: line breaks inside RTL text read in the wrong order at the wrap point. Not addressed here.

## Review Focus

Inputs the spec implies but a straightforward test would miss; each is pinned by a test in the named task.

1. Arabic mixed with wide, emoji or ZWJ cells: the row falls back to the plain path and nothing is misplaced or crashes (Task 2 `unmappable cells fall back`; Task 4 `wide cell row takes the plain path`).
2. Cursor on every column of a shaped row, including a tashkeel base, the second cell of lam-alef, a kashida-fitted word, and the cell after the text: always a finite box inside the grid (Task 2 `every column has a box`; Task 4 `cursor box on a shaped row`).
3. Box-drawing rows containing Arabic: bars stay on their columns, never mirrored (Task 1 `box row is ltr`; Task 4 `box row keeps its bars`).
4. A row filled edge to edge with Arabic, and windows 1 or 2 columns wide: ink stays inside the grid, no panic (Task 4 `full width row stays inside the grid`, `tiny grids`).
5. Editing a row must never show a stale layout, and the row cache stays bounded (Task 5 `changed row is reshaped`, `cache is capped`).

---

### Task 1: Row facts: which rows need layout, and base direction

**Files:**
- Create: `src/rowfacts.zig`
- Modify: `build.zig` only if the new file is not reachable from `core`'s root (check; `src/shape/layout.zig` is the pattern)

**Interfaces:**
- Consumes: `bidi.classOf(cp: u21) Class`.
- Produces:
  - `pub const Policy = enum { auto, ltr, rtl };`
  - `pub const Facts = struct { needs_layout: bool, rtl_base: bool };`
  - `pub fn analyze(cps: []const u21, policy: Policy) Facts` where `cps` is the row's codepoints in logical order, blank cells as `' '`.

- [ ] **Step 1: Write the failing tests** in `src/rowfacts.zig`. A helper `facts(str, policy)` decodes UTF-8 to `[]u21`. Tests, with the brief 4.7 strings:
  - `needs layout`: `"hello world"` false; `"مرحبا world 123"` true; `"١٢٣"` false (AN only); `"ls ملف.txt"` true; `"a\u{202B}b"` true (RLE); `""` false.
  - `base auto`: `"مرحبا world 123"` rtl; `"السلام عليكم."` rtl; `"world مرحبا"` ltr; `"ls ملف.txt"` ltr; `"➜  ~ الحمد لله"` ltr (prompt); `"❯ مرحبا"` ltr; `"  مرحبا"` rtl (leading blanks skipped); `"١٢٣ مرحبا"` ltr (first non-blank is AN).
  - `box row is ltr`: `"│ مرحبا    │"` auto gives ltr and needs_layout true; the same row with `.rtl` gives rtl (override wins).
  - `overrides`: `"hello"` with `.rtl` gives rtl_base true but needs_layout false.
- [ ] **Step 2: Run** `-Dtest-filter=needs layout` and the other filters. Expected: FAIL (module missing / `analyze` undefined).
- [ ] **Step 3: Implement `analyze`** in one pass over `cps`: set `needs_layout` on the classes in Decision 1; for `auto`, find the first non-blank cp, require class R or AL, and reject if any cp is in U+2500 to U+259F.
- [ ] **Step 4: Run** the filters, then the whole suite. Expected: all pass.
- [ ] **Step 5: Commit** `rowfacts: which rows need layout and their base direction`.

---

### Task 2: Row shaper: cells to text, layout, and a pixel box per column

**Files:**
- Create: `src/rowlayout.zig`
- Test: same file (tests need Menlo; the Phase 1 layout tests already depend on system fonts)

**Interfaces:**
- Consumes: `rowfacts.Facts`, `layout.Layouter` (`layoutRow`, `extents`, `intern`, `font`), `vt.Cell`, `ct.CTFont`.
- Produces:
  - `pub fn rowText(cells: []const vt.Cell, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!?u16`: appends the row as UTF-8 (blank cell becomes a space, trailing blanks trimmed) and returns the number of cells, or `null` if any cell is unmappable (Decision 6: `.wide`, `.spacer_tail`, `.spacer_head`, or a later codepoint that is not a combining mark; use the same mark test as `layout.zig`, made `pub` as `layout.isMark`).
  - `pub const Span = struct { x0: f32, x1: f32 };`
  - `pub const RowLayout = struct { placed: []layout.Placed, spans: []Span, rtl_base: bool, n_cells: u16 }` with `pub fn span(self: RowLayout, col: u16, cell_w: f32) Span` (cells at or past `n_cells` return `col * cell_w` to `(col + 1) * cell_w`) and `pub fn deinit(self: *RowLayout, gpa: Allocator) void`.
  - `pub const Shaper = struct { pub fn init(gpa, primary: *const ct.CTFont, cell_w: f32) Shaper; pub fn deinit(self: *Shaper) void; pub fn shape(self: *Shaper, text: []const u8, n_cells: u16, rtl_base: bool) !?RowLayout }` (model `.d`, `arabic = primary`). Returns `null` when the layout's `n_cells` differs from the argument (Decision 6 guard).

- [ ] **Step 1: Write the failing tests.**
  - `unmappable cells fall back`: a row with a `.wide` cell, one with `.spacer_tail`, and one whose cell has cps `{0x1F468, 0x200D, 0x1F469}` all give `rowText == null`; a cell `{0x645, 0x64E, 0x651}` (base plus two marks) is fine; blanks become spaces and trailing blanks are trimmed.
  - `every column has a box`: for `"مُحَمَّد لا إله إلا الله"` (tashkeel, lam-alef, spaces): every column `0..n_cells` has `x1 > x0`, finite values, `x0 >= 0`, `x1 <= n_cells * cell_w + 0.5`, and boxes of different columns do not overlap by more than 0.5 px (sort by `x0`). A column past the text (`n_cells`, `n_cells + 3`) returns the plain `col * cell_w` box.
  - `plain LTR text keeps cell boxes`: `"ls ملف.txt"` with `rtl_base = false`: the boxes of `l`, `s` and the space are `col * cell_w` wide `cell_w`.
  - `rtl row order`: `"مرحبا"` with `rtl_base = true`: `span(0).x0 > span(4).x0` (first letter rightmost); with `rtl_base = false` the same.
  - `shape guard`: asking `shape` with `n_cells` one larger than the text's returns `null`.
  - `empty and blank rows`: `""` and `"   "` give `n_cells` 0 and a valid empty layout (no crash).
- [ ] **Step 2: Run** `-Dtest-filter=unmappable` etc. Expected: FAIL (undefined).
- [ ] **Step 3: Implement** `rowText`, `RowLayout`, `Shaper`. Fill `spans` (one per logical column) from `Layouter.extents`, which model d fills for every cluster including cells outside fitted words (assert that every column is covered exactly once; a hole is `error.LayoutHole` and the caller falls back). Copy `placed` out of the layouter's scratch list so the layout owns it.
- [ ] **Step 4: Run** the filters, then the whole suite. Expected: all pass.
- [ ] **Step 5: Commit** `rowlayout: cells to shaped row with a pixel box per column`.

---

### Task 3: Cross-check CoreText's visual order against our UAX #9

**Files:**
- Modify: `src/rowlayout.zig` (tests only; `layout.zig` unchanged)

**Interfaces:**
- Consumes: `bidi.resolve(gpa, cps, dir, levels) !u8`, `bidi.reorder(levels, order)`, `Shaper.shape`, `RowLayout.spans`.
- Produces: golden tests only (brief 4.6), plus a ledger note of any disagreement.

- [ ] **Step 1: Write the test** `visual order agrees with UAX #9`. For each brief 4.7 string (`مرحبا world 123`, `السلام عليكم ورحمة الله`, `مُحَمَّد`, `لا إله إلا الله`, `ls ملف.txt`, `"النتيجة: ١٢٣ (ناجح)"`, `echo "اختبار" | wc -c`, `│ مرحبا    │`) and each base the policy picks for it: compute levels with `bidi.resolve`, take cell-level levels (the level of each cell's base character), run `bidi.reorder`, and compare the resulting cell order with the cells sorted by `span.x0` of the layout. Assert equality of the two orders.
- [ ] **Step 2: Run** `-Dtest-filter=agrees with UAX`. Expected: it either passes (record "no disagreement on the 8 samples") or fails with a specific string. A failure is not a bug to patch over: find which side is wrong (read both orders in the failure message), then rule in the ledger, either fix the cell-level mapping in the test or record that CoreText and UAX #9 differ for that input and why.
- [ ] **Step 3: Commit** `rowlayout: golden order tests against UAX #9`.

---

### Task 4: Painter draws shaped rows and the cursor on them

**Files:**
- Modify: `src/draw.zig`

**Interfaces:**
- Consumes: Tasks 1 and 2, `vt.Terminal.update/selectRow/cellInRow/size/cursor`.
- Produces:
  - `Painter.policy: rowfacts.Policy = .auto` (pub field).
  - `Painter.stats: struct { shaped_rows: u32 = 0, plain_rows: u32 = 0, cache_hits: u32 = 0 }` (pub; counters are cheap and make the fast path testable).
  - `drawRows` behavior: per row, gather the row's cells; `rowText`; if `null` or `analyze(...).needs_layout == false`, take the existing per-cell path (`plain_rows += 1`); else `shape` and draw `placed` glyphs (each glyph at `x`, baseline `top + ascent`, horizontally scaled by `sx`; clip to the grid as before). Shaping failure or `null` falls back to the plain path.
  - Cursor on a shaped row: fill the cell's `span` box in the foreground color, then redraw the row's glyphs in the background color clipped to that box. Elsewhere unchanged.

- [ ] **Step 1: Write the failing pixel tests** with the existing `Canvas` harness and a real `vt.Terminal` fed through `write`. A helper renders a screen of N columns and returns the canvas and the painter's stats.
  - `latin rows take the plain path`: a screen of `hello` and `ls -la` gives `shaped_rows == 0` and `plain_rows` equal to the rows drawn.
  - `arabic word is joined`: `بيتي` (four letters that all join) at column 2: `shaped_rows == 1`; ink exists inside columns `2..6`; inside the word's ink bounds no pixel column is blank for more than 1 px in a row; no ink at columns `>= 6`. (If the font cascade fails this by a measured margin, record the numbers in the ledger as a ruling.)
  - `box row keeps its bars`: `│ مرحبا    │`: ink at the center column of cell 0 and of cell 11 (the bars), none in cells 12 and beyond; `shaped_rows == 1`.
  - `rtl row is right to left`: `مرحبا` at column 0: the rightmost letter's ink starts right of the leftmost's; checked through `RowLayout` spans via a `Painter` test accessor or by pixel centers of the first and last cells.
  - `cursor box on a shaped row`: cursor on the third letter of `مرحبا` (after `ESC[1;3H`): the block interior pixel is the foreground color and ink in the block is the background color somewhere; cursor at column 20 (past the text) is at `20 * cell_w`.
  - `wide cell row takes the plain path`: a row with `مرحبا` and an emoji (a `.wide` cell) gives `shaped_rows == 0`; drawing does not crash.
  - `full width row stays inside the grid`: a screen 40 columns wide filled with Arabic letters: all ink is inside `0..40*cell_w`; `tiny grids`: the same draw into 1 and 2 column grids does not panic and leaves the bitmap outside the grid empty.
- [ ] **Step 2: Run** `-Dtest-filter=latin rows` and the others. Expected: FAIL (`stats` and `policy` undefined).
- [ ] **Step 3: Implement** the Painter changes. The Painter owns one `rowlayout.Shaper`; Arabic font is `primary` (Global Constraints). Draw one `CTFontDrawGlyphs` call per placed glyph for now (measured in Task 5). Keep the plain path code as it is.
- [ ] **Step 4: Run** the filters, then the whole suite. Expected: all pass, slice 2's draw tests unchanged.
- [ ] **Step 5: Run** `macos/build-app.sh` and `Harf --selftest`. Expected: `selftest ok`.
- [ ] **Step 6: Commit** `draw: shaped Arabic rows and the cursor on them`.

---

### Task 5: Bounded row cache and a measured cost

**Files:**
- Modify: `src/draw.zig`, `docs/perf.md`

**Interfaces:**
- Consumes: Task 4's shaped-row path.
- Produces: `Painter.row_cache` with a hard cap (`max_cached_rows = 128`); a hit skips `shape` and bumps `stats.cache_hits`. The key is the row's text bytes plus `rtl_base` plus `cell_w`; entries store the text and compare it on lookup, so a hash collision can never return another row's layout. When full, the cache is cleared before inserting (`ponytail:` comment: clear-all, per-row LRU if the numbers ask for it).

- [ ] **Step 1: Write the failing tests.**
  - `same row twice shapes once`: draw a screen with one Arabic row twice; `shaped_rows` counts layouts (1) and `cache_hits == 1`.
  - `changed row is reshaped`: draw `مرحبا`, then overwrite it with `مرحبي` on the same row and draw again: the pixels differ from the first draw and `shaped_rows == 2`.
  - `cache is capped`: draw 1,000 distinct Arabic rows (rewrite one row 1,000 times); the cache entry count never exceeds 128 and, run under `std.testing.allocator`, nothing leaks after `deinit`.
  - `cached and fresh draws match`: the canvas after a cache hit equals the canvas after a cold shape, byte for byte.
- [ ] **Step 2: Run** `-Dtest-filter=same row twice` etc. Expected: FAIL.
- [ ] **Step 3: Implement** the cache inside `Painter`; free entries in `deinit`.
- [ ] **Step 4: Measure.** Add a `--selftest` line in `main.swift` that prints the time to draw a 24-row screen of full-width Arabic cold and warm (use `Release` via `macos/build-app.sh` if it builds release; note which). Record both numbers, machine, date and build in `docs/perf.md` (new section "Phase 4 shaped rows"). No pass/fail threshold here; the number is the deliverable. If cold draw of one full screen exceeds 50 ms, say so in the ledger as a finding.
- [ ] **Step 5: Run** the whole suite and `Harf --selftest`. Expected: pass, `selftest ok`.
- [ ] **Step 6: Commit** `draw: bounded shaped-row cache; perf numbers`.

---

### Task 6: End-to-end evidence, owner checklist and docs

**Files:**
- Modify: `macos/Sources/Harf/main.swift`, `ARCHITECTURE.md`, `docs/cell-model.md`
- Create: `docs/phase4-manual-check.md`, `docs/phase4/` (two PNGs)

**Interfaces:**
- Consumes: the finished Painter, the existing `HARF_SELFTEST_PNG` hook.
- Produces: a self-test that proves Arabic is shaped in the real window path, two inspected pictures, and the owner's checklist.

- [ ] **Step 1: Self-test.** Add to `--selftest`: a child that prints the brief 4.7 sample strings with `printf`; after it settles, `rows(...)` still returns the logical text (copy stays logical), and drawing the view into a bitmap through the existing `harf_term_draw` path shows ink on every sample row. Assert on pixels only; the Zig tests already cover the counters, and the C ABI does not grow.
- [ ] **Step 2: Pictures.** With the PNG hook, render (a) the brief 4.7 screen and (b) the typing sequence `السلام عليكم` fed one letter at a time at an LTR prompt row `❯ ` and at a bare RTL row, as side-by-side frames showing the cursor. Read both PNGs yourself and note in the ledger what you see (joins, order, brackets, drift). Save them under `docs/phase4/`. The owner judges visual quality (brief 4.7); do not claim they look right, say what you observed.
- [ ] **Step 3: Checklist** `docs/phase4-manual-check.md` for the owner, one line each: the 8 brief strings via `printf` in the app; typing `السلام عليكم` at the zsh prompt (drift acceptable?); `echo "اختبار" | wc -c`; an indented Arabic line (`  مرحبا`, Decision 2's known quirk); a box row; `ls` in a directory with Arabic file names; resize while Arabic is on screen; open `claude` and type Arabic in its input box; Option+Left over Arabic (logical, Decision 5).
- [ ] **Step 4: Docs.** `ARCHITECTURE.md` decision-log row for Phase 4 (policy, fast path, cache cap, CoreText stays the shaper, UAX #9 cross-check result from Task 3); `docs/cell-model.md`: replace "typing alignment deferred to Phase 4" with the status after Task 6's picture, and list what is still open (cursor rule, ink centering, soft-wrapped paragraphs).
- [ ] **Step 5: Run** the whole suite, `macos/build-app.sh`, `Harf --selftest`. Expected: all pass, `selftest ok`.
- [ ] **Step 6: Commit** `phase 4: end-to-end check, pictures, owner checklist, docs`.

---

## Self-review

- Spec coverage (brief Phase 4: "per-row layout, logical/visual maps, cursor placement, base-direction policy (4.4), typing behavior (4.5)"): per-row layout and maps Tasks 2 and 4; cursor Task 4; base direction Task 1; typing behavior Decision 4 plus Task 6's picture and checklist, with the owner's judgement still pending; conformance golden tests (4.6) Task 3. Not covered on purpose: selection, mouse hit-testing and copy through the map (Phase 7), OSC 133 regions (Phase 6), config UI (Phase 6), our UAX #9 as the layout authority (follow-up if Task 3 finds a disagreement), ink centering and kashida tuning (cell-model.md), per-paragraph bidi across soft wraps (Decision 8).
- The known weak spot is the cursor and typing drift. Decision 4 is a default, not a verdict. The owner should look at Task 6's pictures before this phase is called done.
- Types: `Policy`, `Facts`, `Span`, `RowLayout`, `Shaper`, `Painter.stats` and `Painter.policy` are named once in Interfaces and used with the same names in later tasks.
