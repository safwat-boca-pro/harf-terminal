# Slice 3 review follow-ups and draw performance: claims and proofs

**Purpose.** Turn the review of `.superpowers/sdd/2026-11-14-phase3-slice3-daily-use/` and the validation of the pasted performance analysis into work items. Each item states a **claim**, the **evidence already in hand**, the **proof still to produce**, and a **done-when** line. Nothing here is done until its proof exists.

**Branch:** work on a new branch from `phase3-slice3` (suggest `slice3-followups`). Do not rewrite the slice 3 commits.

## Global constraints (unchanged from the slice 3 plan)

- Zig 0.17.1 pinned. Tests: `.tools/zig/zig build test --summary all`; filter with `-Dtest-filter=<text>`. Bench runs use `-Doptimize=ReleaseFast`.
- `include/harf.h` stays in sync with `src/capi.zig`. Swift never sees libghostty headers.
- Idle cost zero: no timers or polling in product code. A poll timeout that exists only while a bounded condition holds needs the owner's explicit approval (item P2).
- 30 MB `phys_footprint` at 700x420 pt: every new cache keeps a hard cap and a test that shows it.
- No attribution trailers or AI mentions in commits, docs or code (user's global rule).
- A claim about speed is not proven by reading code. It needs a before/after number from the same harness, recorded in `docs/perf.md` with machine, date and build.

## Evidence already collected (the baseline this plan builds on)

Painter-only, plain Latin, 80x24 at 28 px, ReleaseFast, Apple M1, `CGBitmapContext`, average of 300 frames. This excludes AppKit layer and compositing time, so it is not an end-to-end number. The throwaway benchmark that produced it was reverted; Task P0 makes it repeatable.

| What | µs |
|---|---|
| Full frame (`drawRows`, all 24 rows) | 1716 |
| One row (`drawRows(5, 5)`) | 71 |
| 1920 glyph calls, per-glyph save/translate/scale/restore | 1443 |
| The same calls, no state ops | 1273 |
| One `CTFontDrawGlyphs` call per row | 248 |
| Mixed glyphs, per-glyph vs one call per row | 1700 vs 321, 0 of 4,308,480 bytes differ |
| `gather` for all 24 rows (about 8 C calls per cell) | 44 |
| `selectRow` x24, `update` | under 1 each |
| `rowfacts.analyze` x24 rows | 17 |

Also established by reading the vendored libghostty-vt 1.0.1 headers and source:

- `ghostty_render_state_begin_update` / `end_update` exist and are documented for lock-split use (`render.h:651-713`).
- Render-state dirty flags are sticky until the caller cleans them (`src/terminal/render.zig:322-325`, `:1396-1413`, `:1488-1492`); `update` only raises them.
- `GHOSTTY_TERMINAL_OPT_RENDER_HOLD` reports mode 2026 holds, and ends them on RIS and resize (`terminal.h:1893-1921`, `:2558-2565`).
- Bulk reads exist: `ghostty_render_state_row_cells_get_multi` (`render.h:1201`), `ROW_DATA_CELLS_RAW` (`render.h:471`).
- The only `bidi.resolve` caller is inside a test (`rowlayout.zig:290`).

---

## Part A: Draw performance

### P0. A repeatable painter-only benchmark (do this first)

- **Claim:** Every later performance claim needs the same harness, or the numbers are not comparable.
- **Evidence now:** The numbers above, from a reverted throwaway test.
- **Proof to produce:**
  1. A `test "bench: ..."` in `src/draw.zig` that returns early unless `HARF_BENCH=1` is set, so the normal suite stays fast and green.
  2. It prints: full frame, one row, and (for Arabic) cold and cached frame, each as the mean of at least 300 frames after 10 warm-up frames.
  3. Run it on the unchanged branch head and record the table in `docs/perf.md` under a new "Follow-ups baseline" heading, with machine, macOS version, Zig version, date and commit.
- **Done when:** the baseline table is in `docs/perf.md` and `HARF_BENCH=1 .tools/zig/zig build test -Dtest-filter=bench -Doptimize=ReleaseFast` reproduces it within noise.

### P1. Batch glyph draws (plain path, then shaped path)

- **Claim:** Glyph draw calls are about 84% of a plain frame. Drawing one call per run instead of one per glyph cuts the glyph cost about 5x with identical pixels.
- **Evidence now:** The table above. Code sites: `drawCell` (`draw.zig:209-222`) and `drawShaped` (`draw.zig:305-321`). Most of the cost is the call itself, not the state ops, so setting the text matrix once alone would recover only about 10%.
- **Rule to implement:** within a row, collect consecutive glyphs and draw them in one `CTFontDrawGlyphs` call; end the run when the **font** (including fallback font), **face**, or **foreground colour** changes, or at a skipped cell (blank, invisible). Flip the context once per row (save, translate, scale, restore), not once per glyph. Positions stay `col * cell_w`, so the grid cannot drift. Combining marks share their cell's x. On shaped rows, batch only glyphs with `sx == 1` and draw the rest individually.
- **Proof to produce:**
  1. **Parity test:** the batched output equals the per-glyph output byte for byte on a screen that mixes: Latin, a fallback-font glyph (Arabic or CJK), bold and italic faces, colour changes mid-row, faint, invisible cells, a wide cell, a combining mark, and a shaped Arabic row. Keep the old per-glyph routine as a test-only reference so the comparison stays runnable.
  2. All existing `draw` tests pass unchanged (slice 2, Phase 4 and slice 3 pixel tests).
  3. `Harf --selftest` prints `selftest ok`, and the four `docs/slice3` pictures regenerate pixel-identical (or the difference is explained).
  4. **Number:** with P0's harness, plain full frame drops from 1716 µs to at most 700 µs. Record before and after. Also record the Arabic cached frame (baseline about 2.1 ms in `docs/perf.md`); if it does not improve, say so.
  5. A mutation check: break the run-ending rule on colour change and confirm the parity test fails.
- **Done when:** items 1 to 5 hold and the numbers are in `docs/perf.md`.
- **Stop condition:** if the parity test cannot be made exact (sub-pixel differences from batching), stop and report the difference rather than loosening the test.

### P2. Synchronized output (mode 2026) through the library's render hold

- **Claim:** Harf can show a half-drawn frame when a program redraws inside `ESC[?2026h ... ESC[?2026l` (Claude Code, Codex and similar). The library already reports the hold; Harf ignores it.
- **Evidence now:** `ioLoop` (`term.zig:381-412`) does one read, parse and wake per poll cycle; no `RENDER_HOLD` is registered in `vt.zig` `init`.
- **Design:** register `GHOSTTY_TERMINAL_OPT_RENDER_HOLD`. The callback runs inside `vt_write` on the I/O thread with `term_lock` held, so it may only set an atomic flag. While the flag is set, `requestWake` does nothing; when the hold ends (the library also ends it on RIS and resize), call the wake once. No second lock, no allocation in the callback.
- **Owner decision needed:** a safety deadline (so a program that never resets 2026 cannot freeze the display). Options: (a) none, trusting the library's end-of-hold events; (b) `poll` with a timeout of about 100 ms used only while a hold is active, which stops the moment the hold ends. (b) is bounded and not idle cost, but it is a timer by another name, so it needs approval.
- **Proof to produce:**
  1. **Session test:** a child sends `?2026h`, writes part one, sleeps, writes part two, sends `?2026l`. Assert zero wakes during the hold and exactly one wake after release, and that the grid then holds both parts.
  2. A test that a hold is released by RIS and by `resize`.
  3. A test that the callback does not deadlock (the child floods output while holding).
  4. `bench/idle.sh` idle CPU stays at the Phase 0 level (0.01% mean) with a window open and no output.
  5. Add to `docs/slice3-manual-check.md` (or a new check file): run a program that redraws under 2026 and confirm no tearing. This one only the owner can judge.
- **Done when:** items 1 to 4 pass, the deadline decision is recorded in the ledger, item 5 is on the owner's checklist.

### P3. Dirty-row invalidation (gate: only after P1)

- **Claim:** Redrawing only changed rows costs about 71 µs per row instead of about 1.7 ms per frame (24x on a plain screen).
- **Evidence now:** the one-row measurement. Plumbing exists: `wakeOnMain` invalidates everything (`TerminalView.swift:201`), while `draw(in:dirty:)` already maps a dirty rect to rows (`:218-228`).
- **Gate:** after P1 the full frame should be about 0.5 ms. If it is, dirty rows are an energy optimization, not a latency one. Proceed only if the owner wants the battery win; record that decision in the ledger.
- **Hazards that must each have a test:** the cursor's old and new rows; focus change (hollow vs solid cursor); selection changes; viewport scroll; resize; alternate-screen switch; palette and OSC 10/11 changes (full redraw); a row whose only change is its style. After a full successful frame call `ghostty_render_state_clean`.
- **Proof to produce:**
  1. **Differential test:** a scripted sequence of writes, cursor moves, selections and scrolls; after each step, a partial redraw (only dirty rows) must produce the same pixels as a full redraw.
  2. One test per hazard above.
  3. Number: single-character echo on a plain screen, frame cost before and after, in `docs/perf.md`.
- **Done when:** the differential test passes over the whole script and the hazard tests exist.

### P4. Two-phase render-state lock (gate: a measured problem)

- **Claim:** `harf_term_draw` holds `term_lock` for the whole draw (about 1.7 ms plain, about 15 ms Arabic cold), which can delay the I/O thread during a flood.
- **Correction to the pasted analysis:** `term.size()` and `hasSelection()` (called from `update`) read the terminal handle, so they stay inside the lock or must be cached. Splitting only `begin_update` / `end_update` is not enough by itself.
- **Gate:** first measure parse throughput of a flooding child while the main thread draws continuously. Proceed only if throughput drops meaningfully compared with no drawing.
- **Proof to produce:** the flood measurement before and after; a thread-safety argument that, after unlock, drawing touches only the render state, row iterator and painter (all main-thread); the full suite and `--selftest` pass.
- **Done when:** a measured improvement is recorded, or the item is closed as "not needed" with the measurement.

### P5. Items measured as not worth doing (record, do not implement)

- **Per-cell FFI and row iteration** (pasted claim 1.4): the whole `gather` is 44 µs and `selectRow` is under 1 µs. Record this in `docs/perf.md`. If it ever matters, use `row_cells_get_multi`.
- **ASCII fast exit** (claim 1.5): all of `rowfacts.analyze` is 17 µs per frame. Do **not** change `bidi.classOf` (ASCII digits are `EN` at `tables.zig:28`). A guard in the first loop of `rowfacts.analyze` only would be safe but gains about 1%; do not add it without a measured need.
- **Deferred:** CoreText churn (claim 1.6; measure the arena and paragraph style costs first, and replace clear-all with a two-generation cache only if the scrolling hitch shows up), zero-allocation `bidi.resolve` (when Phase 7 wires it in), search over logical text (Phase 6), `simd = true` (only if `vtebench` shows parsing is the bottleneck; the spec says SIMD helps Arabic text only).

---

## Part B: Slice 3 review findings

### R1. Trackpad scrolls about 3x too fast in mouse-tracking programs (Important)

- **Claim:** `Session.scroll` sends `ceil(|rows|/3)` wheel events per call (`term.zig:232`). The Swift trackpad path calls with 1 or 2 whole rows at a time, so each call sends one event, and a program treats an event as about 3 lines.
- **Evidence now:** code reading only. The existing test pins `scroll(-1)` giving one event, which is the round-up.
- **Proof to produce:**
  1. A test that three calls of `scroll(-1)` with tracking on send **one** wheel event in total (the remainder is carried), and `scroll(-3)` sends one.
  2. A test that the carried remainder resets on direction change and when tracking turns off.
  3. Owner check: `vim` with `:set mouse=a`, a two-finger drag of about 10 rows scrolls about 10 lines, not about 30.
- **Done when:** tests 1 and 2 pass and the manual check is on the owner's list.

### R2. Hit-testing on lam-alef and tashkeel is not pinned (Important)

- **Claim:** The slice 3 plan's Review Focus 1 promises that a click on a shaped row lands on the drawn cell, including the second cell of lam-alef and a tashkeel base. The tests only cover `مرحبا` and the blank cells past the text. The lam-alef and tashkeel copy tests (`vt.zig:1198-1199`) use cell coordinates and never go through `cellAt`.
- **Evidence now:** the gap is confirmed by reading the tests. Whether the behavior is correct is **unknown** until tested.
- **Proof to produce:** tests through `Painter.cellAt` and `harf_term_selection_event` for (a) the center of the second cell of lam-alef, (b) a tashkeel base letter, (c) blank cells after the text. Each asserts the returned column, and a press-drag-release over the pixels copies the expected logical text. If a test fails, that is a real bug: fix it in `rowlayout`/`cellAt`, not in the test.
- **Done when:** the three cases pass, or each failing case has a ruling and a fix.

### R3. "Cursor row intact" after a wheel flood is not asserted (Minor)

- **Claim:** Review Focus 2 says a flood keeps the cursor row intact; `viewport clamps` (`vt.zig:1085`) checks offsets and the oldest line only.
- **Proof to produce:** after the flood and `scrollToBottom`, assert the cursor position and the content of the active rows equal their values before the flood.

### R4. OSC 11 does not change the margins (Minor)

- **Claim:** `TerminalView.draw` fills the dirty rect with a hardcoded colour (`TerminalView.swift:341-342`) while the painter uses the render-state background, so after OSC 11 the 6-pt inset and the strip past the last whole cell keep the old colour. This contradicts Decision 1.
- **Proof to produce:** a pixel test (a painter-level or `--selftest` step) that after `OSC 11 ; rgb:ff/ff/ff` the margin pixels match the new background. Fix by having the view take the background from the core instead of the constant.

### R5. Hairline seams between adjacent shaped-row backgrounds (Minor, needs confirmation)

- **Claim:** Each column's background on a shaped row is filled separately at fractional span edges (`draw.zig:422-426`), which can leave faint vertical lines. I think I see them in `docs/slice3/arabic-colors.png` and `selection-arabic.png`, but I did not zoom.
- **Proof to produce:** first view both pictures at 1:1 and confirm or drop the finding. If confirmed: a pixel test that two adjacent columns with the same background leave no pixel differing from that background at their shared edge; fix by snapping span edges to whole pixels or merging runs of equal background as the plain path does.

### R6. Wheel events run a full hit-test just to record the pointer (Minor)

- **Claim:** `scrollWheel` calls `mouse(2, 0, SHIFT)` on every event (`TerminalView.swift:330`). Shift bypasses the early-out at `capi.zig:174`, so each event runs `update`, `gather` and a shape lookup even when no program tracks the mouse.
- **Proof to produce:** record the pointer cell only while tracking is on (or compute it lazily in `Session.scroll`); a test that tracking-on wheel events still carry the right cell. The saving is small (about 44 µs plus a shaping lookup), so this is low priority.

### R7. Mode 1007 (alternate scroll) is never read (Minor, owner decision)

- **Claim:** The alternate-screen wheel sends arrow keys regardless of the program's mode 1007 setting (`term.zig:234`); the constant exists in `modes.h`.
- **Decision needed:** honor 1007 (xterm behavior) or keep the current convention and say so in `ARCHITECTURE.md`.
- **Proof to produce:** if honored, a test that with `?1007l` on the alternate screen the wheel sends nothing, and with 1007 on it sends arrows.

### R8. Double-click then drag drops the word selection (Minor, owner decision)

- **Claim:** `selectionDrag` (`vt.zig:324-333`) replaces a word or line selection with a character range from the press cell. Most terminals extend by word.
- **Proof to produce:** if wanted, a test that double-click then drag extends in whole words.

---

## Part C: Documentation and evidence fixes

- **D1. Plan drift.** `docs/superpowers/plans/2026-11-14-phase3-slice3-daily-use.md` Decision 9 and the Task 6 test `output that changes the selection clears it` still say output clears the selection. The ledger and `ARCHITECTURE.md` row 54 say the library keeps it. Update the plan to match (or add a "superseded by ledger" note) so a reader of the plan is not misled.
- **D2. Test evidence in the ledger.** The ledger quotes `+- run sh success 122ms`, which is the UCD-fetch step, and the seven `task-N-tests.log` files are cached step trees with no counts. From now on record the line that shows the test result and the test count. For slice 3 the evidence is: full suite passes (42/42 steps), 169 named plus 2 unnamed test blocks, which matches the handoff's 171.
- **D3. `docs/perf.md`.** Add the baseline from P0, a "measured and rejected" note for P5, and each follow-up's before and after.

---

## Order and gates

1. **P0** (baseline) first, then **D3** for the baseline.
2. **R1** and **R2**: the two Important findings; independent of performance work.
3. **P1** (batching): the largest measured win. Everything in Part A after it is re-measured against P1's result.
4. **P2** (render hold) after the owner decides the deadline question.
5. **R3 to R8**, in any order; R7 and R8 wait for owner decisions.
6. **P3** and **P4** only if their gates say so. **P5** items are documentation only.
7. **D1, D2** at the end of each task as the work lands.

## Owner decisions needed before work starts

1. P2: no deadline, or a bounded 100 ms poll timeout while a hold is active.
2. P3: is the battery win worth the invalidation complexity once P1 lands?
3. R7: honor mode 1007, or keep arrows regardless.
4. R8: word-granular drag after a double-click, or leave as is.

## Stop condition

The work is finished when every item above is either **proven** (its proof exists and is recorded), **closed with a measurement** showing it is not needed, or **waiting on a named owner decision**. No item is closed on code reading alone.
