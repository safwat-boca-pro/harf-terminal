# Performance

Budgets: see `PROJECT_BRIEF.md` section 7. Measure before optimizing; record every run here.

## Method (Phase 0 baseline, keep identical for later runs)

- **Build:** Release (`zig build -Doptimize=ReleaseFast`, `swift build -c release`) via `macos/build-app.sh`.
- **Launch:** `open macos/.build/Harf.app`, wait 5 s for the first frame, then leave the window untouched and unfocused-safe (no input).
- **Memory:** `footprint <pid>` (phys_footprint) and `ps -o rss= -p <pid>` (KB).
- **Idle CPU:** `ps -o %cpu= -p <pid>` sampled every 2 s for 60 s; record mean and max. Also record cumulative CPU time (`ps -o time=`) before and after, which is more reliable than `%cpu` at near-zero load.
- **Record** machine model, chip, macOS version, Xcode/Swift and Zig versions with every row.

## Results

| Date | Build | Machine / OS | RSS (MB) | phys_footprint (MB) | Idle CPU mean / max (%) | Notes |
|---|---|---|---|---|---|---|
| 2026-11-13 | Release (`macos/build-app.sh`; Zig 0.17.1 ReleaseFast, Swift 6.2.4) | Apple M1, macOS 27.0.1 | 64-67 | 26 (peak 30) | 0.01 / 0.20 (30 samples over 60 s) | empty AppKit + Metal window, Phase 0; `bench/idle.sh` |

Cumulative CPU time over the 60 s idle window: 0:00.40 -> 0:00.42 (0.02 s), consistent with no timers or display link.
The 5 s startup was not timed precisely; first frame is visible by the first sample, so startup is well under any budget so far (not yet measured).

## The 30 MB target: definition and corrected measurements (2026-11-13)

**Definition.** `phys_footprint` from `footprint <pid>`, Release build, one window, empty session, measured 12-20 s after
launch, Apple M1, macOS 27.0.1. **Window size is part of the definition**, because the window's backing IOSurface is charged to
the app and scales with pixel count. Reference sizes: **80x24 class = 700x420 pt content**, and Terminal.app's default
window on this machine = 1162x597 pt content.

**Correction.** An earlier version of this section said Terminal.app is 17 MB and that window pixels live in WindowServer and are
not charged to the app. That was wrong: the 17 MB run had no real window (I never confirmed one existed). With a confirmed
1162x597 window, Terminal.app is **63 MB transient, 50 MB settled**, with a 10-19 MB `IOSurface` line charged to the process.

Controlled prototypes (throwaway, `NSView.draw` with `CTLineDraw` vs an empty `MTKView`, same window size):

| Window (content) | CPU-drawn view | Metal view (3 drawables) |
|---|---|---|
| 700x420 pt (80x24 class) | **25 MB** (IOSurface 5 MB) | 30 MB (IOSurface 9.5 MB) |
| 1162x597 pt | **30-31 MB** (IOSurface 11 MB) | 42-43 MB (IOSurface 22 MB, three surfaces) |

Other apps, same machine (not controlled for content): Terminal.app 50 MB at 1162x597; Ghostty 1.4.0 65 MB
(`Malloc Small` 46 MB, window size unknown). Metal `maximumDrawableCount` 2 vs 3 changed nothing (still three surfaces).

What this says:

- CPU drawing is 5-13 MB lighter than Metal at equal window size, because a layer-backed CPU view keeps one backing
  surface while a Metal layer holds several drawables. That, not "pixels live in WindowServer", is why the renderer change helps.
- Window size dominates. An empty CPU-drawn view is already 25 MB at 80x24 and 30 MB at Terminal's default size, before any
  terminal state exists. **30 MB is plausible at 80x24, not at 1162x597.** The Zig core, grid and scrollback must fit in the
  remaining ~5 MB at 80x24.
- Harf spike with the Metal path, atlas 2048: 34 MB; atlas 1024: 28 MB (window ~1083x248 pt). The atlas existed twice
  (4 MB CPU + 4 MB GPU). The CPU renderer has no atlas.
- **Real CPU-drawn spike app** (Zig core + CoreText, window 1083x362 pt, 2166x724 px): 30 MB at 12 s, 36 MB on a later sample;
  `IOSurface` 11 MB, `Malloc Small` 11 MB, no GPU categories. Idle CPU 0.53 s -> 0.78 s cumulative over the sampling interval (no timers).
  It is not a terminal yet (no grid or PTY), and the window is larger than the 80x24 class, so this is not yet a pass or fail against 30 MB.
- **Same spike app, window pinned to 700x420 pt (80x24 class)** via the `HARF_CONTENT_SIZE=700x420` hook in `main.swift`, Release,
  Apple M1, macOS 27.0.1, run directly (not through `open`): **28 MB `phys_footprint` at 15 s and still 28 MB at 45 s** (RSS 65 MB then 44 MB).
  `Malloc Small` 11 MB, `IOSurface` 9.2 MB, `Malloc Metadata` 0.9 MB. Cumulative CPU 0:00.72 -> 0:00.74 over 30 s idle (no timers).
  Under the 30 MB target by 2 MB, but this is still not a terminal (no grid, PTY, scrollback), and its 11 MB of malloc is the spike's
  font and layout state, not a measured terminal core. **Unexplained:** `IOSurface` here is 9.2 MB (about two 1400x840 surfaces) versus
  5 MB in the throwaway `NSView.draw` prototype at the same window size; the real view may hold an extra backing surface. Worth
  finding before the grid exists, because it is the largest single line the shell controls.
- "Feels faster" is latency, not memory. Keypress-to-pixel is not measured yet.

## Budget status

- **Owner decision (2026-11-13): target 30 MB `phys_footprint`, CPU-drawn renderer** (replaces Metal; brief section 2).
- Idle RSS is not a usable budget: an empty AppKit window is ~60-90 MB RSS because RSS counts shared framework pages. Track `phys_footprint`.
- Status against the target, at the 80x24-class window: empty CPU-drawn view 25 MB. Headroom ~5 MB for the Zig core, grid,
  scrollback and shaping caches. Not yet measured with the real core.
- At larger windows the empty view alone reaches 30 MB (1162x597), so the target only holds for small windows unless
  the backing store is reduced further. Revisit with measured numbers once the real grid exists.
- Idle CPU budget (~0%) was met by the Phase 0 baseline: 0.01% mean. Re-measure for the CPU renderer (it redraws on dirty rects only).
- Throughput against GPU terminals (brief section 7) may drop with CPU drawing; measure with vtebench in Phase 3 and revisit.

## Phase 4: shaped Arabic rows (2026-11-14)

Method: `Harf --selftest` (section 1b). A child prints 40 distinct lines of Arabic text (about 80 columns each); the view then
draws the whole 80x24 grid (700x420 pt, retina) twice with `cacheDisplay`: the first draw shapes every row, the second hits the
row cache (`Painter.max_cached_rows` = 128). Times include AppKit's bitmap path, not only the painter. Three runs each.
Build: `macos/build-app.sh` (Zig 0.17.1 ReleaseFast, Swift release). Apple M1, macOS 27.0.1.

| Draw | ms (3 runs) |
|---|---|
| Cold, 24 shaped rows | 15.3, 14.9, 14.1 |
| Cached, same rows | 2.1, 2.1, 2.1 |

Rows without RTL text never reach CoreText shaping (counted by `Painter.stats.plain_rows` in tests). Not measured: typing latency,
a screen where every wake changes every row, memory with the cache full (128 rows; the footprint measurement is slice 4).

## Slice 3: colored screens (2026-11-14)

Same method as the Phase 4 section (`Harf --selftest`, section 1d): a child prints 40 lines whose color changes on every line,
the view draws the whole 80x24 grid twice with `cacheDisplay`. "Cold" draws every row, "second" reuses cached Arabic layouts
(plain rows have no cache). Release build via `macos/build-app.sh`, Apple M1, macOS 27.0.1, three runs.

| Screen | Cold (ms) | Second draw (ms) |
|---|---|---|
| Colored Latin, per-cell path | 2.9, 3.0, 2.7 | 1.9, 2.0, 1.8 |
| Colored Arabic, shaped path | 14.6, 13.7, 12.9 | 2.7, 2.9, 2.6 |
| Phase 4, uncolored Arabic, for comparison | 12.1 to 17.8 | 1.9 to 2.4 |

Colors and styles did not change the cost of a draw beyond noise (well inside the 2x budget). Not measured: footprint with
the four font faces and the larger glyph keys (slice 4), selection drag redraw, scrolling a large scrollback.

## Follow-ups baseline (2026-11-14, before any follow-up change)

Harness: `test "bench: painter-only frame costs (HARF_BENCH=1)"` in `src/draw.zig`. It is skipped unless `HARF_BENCH=1` is set.
Reproduce: `HARF_BENCH=1 .tools/zig/zig build test -Dtest-filter=bench -Doptimize=ReleaseFast` (Zig caches test runs by inputs, so
change the filter text, for example `bench:`, to force a re-run). Painter only: a 28 px `CGBitmapContext`, no AppKit layer or
compositing, so these are not end-to-end numbers. Mean of 300 frames after 10 warm-up frames. 80x24, every cell inked (1920
glyph calls on the plain screen). Apple M1, macOS 27.0.1, Zig 0.17.1, ReleaseFast, commit 716dfb9.

| What | µs (3 runs) |
|---|---|
| Plain full frame (`drawRows` 0..23) | 1729, 1695, 1696 |
| Plain one row (`drawRows` 5..5) | 74, 74, 73 |
| Colored plain full frame (color change every row) | 1763, 1740, 1745 |
| Arabic shaped, layouts cached, full frame | 1104, 1089, 1090 |
| Arabic shaped, cold (cache cleared each frame) | 6139, 6157, 6169 |

This matches the numbers in `docs/superpowers/plans/2026-11-14-slice3-review-and-perf-followups.md` (plain frame 1716, one row 71).

### Measured and not worth doing (plan item P5)

From the plan's earlier throwaway measurements on the same screen: `gather` for all 24 rows (about 8 C calls per cell) takes 44 µs,
`selectRow` x24 and `update` under 1 µs each, and `rowfacts.analyze` x24 rows 17 µs, against a 1.7 ms frame. Per-cell FFI and
row iteration and an ASCII fast exit in `rowfacts` therefore buy about 1 to 3 percent and are not implemented. If `gather` ever
matters, `ghostty_render_state_row_cells_get_multi` is the tool. Do not change `bidi.classOf` (ASCII digits are class `EN`).

### P1: batched glyph draws (2026-11-14)

Change: a row's glyphs go out in one `CTFontDrawGlyphs` call per run of the same font and color (plain path), and the same
for unscaled shaped-row glyphs that sit on a whole pixel. Same harness and machine as the baseline above (mean of 300 frames,
ReleaseFast, three runs after the change). The old per-glyph routines stay as `Painter.reference_draw`, which the parity tests
use; they check that the two outputs are identical byte for byte on a screen mixing Latin, fallback-font glyphs, a wide cell,
bold, italic, faint, invisible cells, color changes, combining marks, underline, strike, a shaped Arabic row (including a
colored and a bold one) and a box row.

| What | Before (µs) | After (µs) |
|---|---|---|
| Plain full frame | 1729, 1695, 1696 | 507, 500, 505 |
| Plain one row | 74, 74, 73 | 19.8, 19.9, 19.9 |
| Colored plain full frame | 1763, 1740, 1745 | 510, 509, 510 |
| Arabic shaped, cached | 1104, 1089, 1090 | 968, 968, 966 |
| Arabic shaped, cold | 6139, 6157, 6169 | 6037, 6045, 6023 |

Plain full frame is about 3.4 times faster (target: at most 700). The Arabic cached frame improves about 11 percent and the
cold frame about 2 percent: most glyphs of a justified Arabic word sit on fractional pixel positions and are not batched.

**Why fractional positions are not batched.** Drawing every shaped glyph through a batch produced 93 to 155 differing bytes
per small screen. Drawing the same glyphs one at a time through a translation was exact, and so was the plain path (its
glyphs sit at `col * cell_w`, whole pixels). CoreGraphics snaps the positions of a batched call to whole pixels but honors a
translation. So the rule is exact: batch only glyphs at whole-pixel positions, draw the rest as before.

Correction (found while doing R5): `macos/build-app.sh` did not relink the app when only the Zig library changed, so the first
"pictures byte-identical" check for P1 ran against a stale binary. `build-app.sh` now deletes the linked product so it always
relinks. Rechecked with a true build: the `docs/slice3` colors and selection-latin pictures and the three `docs/phase4`
pictures are byte-identical with P1 in the binary, and `Harf --selftest` prints `selftest ok`. In the app the colored plain
80x24 screen now draws in 1.4 ms cold and 0.6 ms on the second draw (it read 2.7 and 1.8 ms on the stale binary), which
includes AppKit's bitmap path.

### P2: synchronized output, idle check (2026-11-14)

After the render-hold change, `Harf` launched directly, window open, no output, 30 s sampled every 2 s: idle CPU mean 0.01
percent, max 0.10 percent, cumulative CPU time 0:00.21 to 0:00.22 (0.01 s over 30 s). The Phase 0 level is 0.01 percent mean.
`phys_footprint` read 40 MB at 5 s and 38 MB at 35 s with the default window; that is not the defined measurement (12 to 20 s
after launch at 700x420 pt) and is the slice 4 question, but it is above the 30 MB target and worth knowing now.
`bench/idle.sh` now starts the binary itself and tracks that pid (it used `pgrep -x | head -1` and `kill`, which could end a
different running copy of the app).

### P4 gate: does drawing slow the parsing of a flood? (2026-11-14)

Harness: `test "bench: flood parse throughput ..."` in `src/capi.zig`, skipped unless `HARF_BENCH=1`
(`HARF_BENCH=1 .tools/zig/zig build test -Dtest-filter='bench: flood parse' -Doptimize=ReleaseFast`, about 1 minute). A child runs
`seq 1 3000000` (about 22 MB of output); the time until it has exited and all output is parsed is measured, alone and with a
second thread drawing the whole 80x24 screen through `harf_term_draw` every 8 ms (about 100 frames per second, more than the
app draws: it draws at most once per display refresh). ReleaseFast, Apple M1, macOS 27.0.1, commit after P1.

| Run | No drawing | Drawing at about 100 fps | Slowdown |
|---|---|---|---|
| 1 | 7.82 s | 8.86 s (873 frames) | 1.13x |
| 2 | 8.50 s | 9.04 s (900 frames) | 1.06x |
| 3 | 8.06 s | 8.43 s (841 frames) | 1.05x |

**Result: not meaningful (5 to 13 percent), so P4 (two-phase render-state lock) is closed as not needed.**

Two other findings:
- A first attempt drew back to back with no gap between frames and the flood did not finish in over five minutes (the drawing
  thread kept re-taking `term_lock` before the parser thread could). That is not a load the app produces, because redraws are
  coalesced to one per wake, but it shows the mutex is unfair. If a future feature draws in a tight loop, revisit P4.
- The flood itself runs at only about 3 MB/s end to end in this harness (a 22 MB `seq` in 8 s). That is far below the
  186 to 448 MB/s the Phase 3 spike measured for parsing alone, so the limit is elsewhere (the child writing through the pty,
  the 64 KiB read size, or the per-wake path). It is a slice 4 (`vtebench`) question, not a P4 one.

## Slice 4 baseline (2026-11-14)

Method: `bench/footprint.sh [settle=15] [mode]`: starts `macos/.build/Harf.app/Contents/MacOS/Harf` itself with
`HARF_CONTENT_SIZE=700x420`, tracks that pid, waits for the child to finish (modes that print first), settles 15 s, reads
`footprint <pid>`, and kills only its own process. Release build (`macos/build-app.sh`, which always relinks), Apple M1,
macOS 27.0.1, Zig 0.17.1, commit c0fc58f plus the script. Target: 30 MB `phys_footprint` at 700x420 pt, empty session.

| State | Footprint (3 runs) | Malloc Small | IOSurface | IOAccelerator (graphics) |
|---|---|---|---|---|
| Settled, empty session, at the prompt | 28, 28, 27 MB | 13 MB | 4976 KB (one surface) | 1.3 MB |
| After printing 6000 lines (1 MiB scrollback full) | 34, 32, 32 MB | 13, 11, 11 MB | 4976 KB once, then 9952 KB (two surfaces) | about 1.3 MB |
| After printing 100 MB, then settled | 32, 32, 31 MB | 11 MB | 9952 KB (two surfaces) | 1.3 MB |

- **The empty settled state is under the 30 MB target** (27 to 28 MB), with margin of 2 to 3 MB.
- **Every state where the view has been redrawn is 2 to 6 MB higher, and most of that is a second `IOSurface`** (9.95 MB instead
  of 4.98 MB: two 1400x904 BGRA surfaces, the window's backing store plus a second drawable). This is the spike's unexplained extra
  surface. It appears once content changes and redraws, not at an idle empty prompt. Task 1 attributes it.
- `Malloc Small` is the largest single line (11 to 13 MB) in every state. It is lower after a flood (11 MB) than at idle (13 MB),
  so most of it is fixed startup state (fonts, frameworks, Swift runtime), not data that grows.
- The ad hoc readings of 38 to 40 MB quoted earlier in `docs/perf.md` were taken 5 s after launch on a stale build (before
  `build-app.sh` relinked) and are superseded by this table.
- A 100 MB `yes | head -c` flood finishes in about 4 s through the real app (about 25 MB/s end to end including drawing).
  The 3 MB/s of the Zig flood benchmark is mostly `seq` itself (it writes one line at a time); Task 3 separates the two.

## Slice 4: where the memory goes (attribution, 2026-11-14)

Experiment: one temporary env-var knob per candidate setting on the window or view (not committed), each run through
`bench/footprint.sh 15 scrollback` (the state that shows the second surface), one run per knob, same machine and build.

| Knob | Footprint | IOSurface | Verdict |
|---|---|---|---|
| none (current) | 31 MB | 9952 KB (two surfaces) | baseline |
| `window.colorSpace = .sRGB` | **26 MB** | **4976 KB (one surface)** | **this is the cause** |
| `window.isOpaque = true` with an opaque background | 32 MB | 9952 KB | no effect |
| `view.wantsLayer = false` | 32 MB | 9952 KB | no effect |
| `view.wantsLayer = true` | 32 MB | 9952 KB | no effect |
| `layerContentsRedrawPolicy = .onSetNeedsDisplay` | 31 MB | 9952 KB | no effect |
| `layerContentsRedrawPolicy = .beforeViewResize` | 32 MB | 9952 KB | no effect |
| `layer.contentsFormat = .RGBA8Uint` | 31 MB | 9952 KB | no effect |
| `window.allowsConcurrentViewDrawing = false` | 32 MB | 9952 KB | no effect |
| `layer.isOpaque = true` | 32 MB | 9952 KB | no effect |
| `layer.contentsScale = 1` | 32 MB | 9952 KB | no effect |

The window's default color space (the display's wide-gamut profile) makes AppKit keep two 1400x904 BGRA surfaces once the view
has been redrawn; with an sRGB window there is one. The spike's unexplained extra surface (9.2 MB against 5 MB in the throwaway
prototype) is this: the prototype never redrew, and the spike did. No other setting tried changes it.

**`Malloc Small` (11 to 13 MB in every state).** `heap -s` at the settled prompt: 60,201 allocations, 8.7 MB in malloc zones,
of which 4.95 MB is "non-object" blocks averaging 157 bytes and the rest is framework state (Objective-C method caches 0.45 MB,
`NSMutableDictionary` storage 0.35 MB, `CFString` 0.28 MB, Swift metadata 0.26 MB, CoreSVG attributes, Metal resource lists).
Zig's allocator maps pages directly, so the terminal, render state, painter caches and glyph cache are not in these zones;
the whole process is only about 2 to 3 MB above the empty CPU-drawn prototype (25 MB at the same window size). Nothing in
`Malloc Small` is Harf state that can be trimmed; it is AppKit.

**Ranked candidates.** 1. sRGB window color space: about 5 MB once the view has redrawn. 2. Nothing else is above the 2 MB
threshold the plan set for a fix.

## Slice 4: footprint after the fix (2026-11-14)

Change: `window.colorSpace = .sRGB` in `AppDelegate` (the attribution above). Same method, build and machine as the slice 4
baseline; three runs per state.

| State | Before (3 runs) | After (3 runs) | IOSurface after |
|---|---|---|---|
| Settled, empty session | 28, 28, 27 MB | **25, 25, 25 MB** | 4976 KB |
| After printing 6000 lines (1 MiB scrollback full) | 34, 32, 32 MB | **26, 26, 26 MB** | 4976 KB |
| After printing 100 MB, then settled | 32, 32, 31 MB | **26, 26, 26 MB** | 4976 KB |

**The 30 MB target holds in every state with about 4 MB of margin** (run-to-run spread under 1 MB). The self-test section
`HARF_MEASURE=1` also checks that a 100 MB flood through a session leaves `phys_footprint` within 2 MB of before: it read
48.0 MB before, 48.6 MB with the flooded session open, 47.6 MB after closing it (the self-test process is larger than the app
because it holds many sessions); no growth. What changes for the eye: the window is now an sRGB window, so colors are
interpreted as sRGB (what the theme and the ANSI palette are defined in) instead of in the display's wide-gamut space; the
`docs/slice3` and `docs/phase4` pictures, which are rendered into a bitmap, regenerate byte-identical.

## Slice 4: throughput (2026-11-14)

**Question.** Is the 3 MB/s the Zig flood benchmark showed (a 22 MB `seq`) a Harf problem?

**Answer: no. It is the PTY, and the child's write pattern.** The same commands through a bare reader (Python `pty`: `os.read(fd, 65536)`
in a loop, no parsing at all) versus through Harf's `Session` (no drawing), ReleaseFast, Apple M1, macOS 27.0.1, one run each:

| Load | Bare reader | Harf `Session` | Bytes per `read` (bare) |
|---|---|---|---|
| `seq 1 3000000` (22.9 MB, a line per write) | 7.54 s, 4.3 MB/s | 7.59 s, 3.0 MB/s | 13 |
| `yes \| head -c 100MB` (full lines) | 3.10 s, 31 MB/s | 3.07 s, 33 MB/s | 99 |
| `head -c 100MB /dev/zero \| tr` (no newlines) | 6.59 s, 14.5 MB/s | 8.15 s, 12.3 MB/s | 1023 |
| `yes \| head -c 100MB \| cat` (large block writes) | 0.71 s, 136 MB/s | 0.99 s, 101 MB/s | 1023 |

- A terminal that parses nothing is exactly as slow on the first two rows, so those loads are limited by the child's writes
  through the PTY (a tty is line-buffered: `seq` makes 2.5 million writes). On large block writes the PTY delivers about 1 KB
  per `read` on macOS whatever the writer does, and a bare reader tops out near 136 MB/s.
- Where Harf adds anything it is 1.24x to 1.39x a bare reader (parsing, one lock and one wake per read), on loads that already
  run at 100 MB/s or more.
- A real 100 MB `yes | head -c` flood through the full app (window drawing) took about 4 s.

**Tried and dropped: draining the PTY before locking.** Reading everything available (up to 64 KB) before taking the lock once
did not move the numbers beyond run-to-run noise (same session: 8.30 vs 8.99 s, 3.40 vs 3.45 s, 8.56 vs 9.15 s, 1.28 vs 1.19 s;
the machine itself varied by 20 percent between sessions). By the rule that a fix must beat its spread it was reverted.

**`vtebench` 0.3.1** (built from source in the scratchpad), run inside the app at 80x24 with `--max-secs 4 --max-samples 20`,
window drawing, 20 samples each; time per sample (each sample is at least 1 MiB of output):

| Benchmark | Mean | Median | p90 |
|---|---|---|---|
| dense_cells | 18.4 ms | 18 | 23 |
| medium_cells | 19.3 ms | 18 | 24 |
| sync_medium_cells | 18.3 ms | 18 | 24 |
| unicode | 10.1 ms | 10 | 16 |
| scrolling | 37.0 ms | 35 | 46 |
| scrolling_bottom_region | 37.5 ms | 36 | 47 |
| scrolling_bottom_small_region | 37.6 ms | 37 | 44 |
| scrolling_top_region | 39.9 ms | 38 | 50 |
| scrolling_top_small_region | 38.5 ms | 38 | 47 |
| scrolling_fullscreen | 49.5 ms | 47 | 62 |

These are absolute numbers; no other terminal was run on this machine, so there is no comparison yet (the brief asks for
"competitive"; comparing needs the other terminals installed and is done only if the owner asks). For scale, one sample of at
least 1 MiB in about 18 to 50 ms is 20 to 55 MiB/s end to end including drawing, against 186 to 448 MB/s for parsing alone in
the Phase 3 spike.

## Slice 4: latency, startup and idle against the budgets (2026-11-14)

Release build (`macos/build-app.sh`), Apple M1, macOS 27.0.1, 700x420 pt window, warm file cache, commit after `8c1d22f`.

### Keypress to pixel: budget under 10 ms

`HARF_MEASURE=1 macos/.build/Harf.app/Contents/MacOS/Harf --selftest` (section 1h) types 200 letters at an idle `cat` prompt through
`TerminalView.handleKey` (the code every key reaches after AppKit decodes the event) and times each from just before the call until
the frame that shows the echo has finished (`measureFrameEnd`, set at the end of `TerminalController.draw`).

| Metric | Result |
|---|---|
| Median | **4.73 ms** |
| p95 | 5.52 ms |
| Max | 6.48 ms |

What the number includes: handing the key to the core, the PTY round trip and the child's echo, parsing, the wake and the hop to
the main thread, and a full-frame draw. It is conservative in one way (the timer also spans `cacheDisplay`'s bitmap setup before
the draw starts) and leaves out two things: waiting for the display's next refresh (up to one frame, about 8 ms on average at
60 Hz) and the compositor. Not measured: the same during a flood (a typed character is not distinguishable in a continuous
stream without extra machinery), and real `NSEvent` delivery (`keyDown` goes through `interpretKeyEvents`, which needs an
active window; the synthetic path starts one call later). The budget holds with margin for the part Harf controls.

### Startup: budget under 100 ms to the first usable frame

`bench/startup.sh 10` (own pid, `HARF_TRACE=startup`): process start (kernel `p_starttime`) to the end of the first frame.

| Run | ms |
|---|---|
| first launch after a rebuild | 1179 |
| the next nine, sorted | 118, 121, 121, 122, 122, 123, 123, 128, 128 (median 122) |

Where the time goes, from one traced launch (`HARF_TRACE=startup` prints each step; about 155 ms with the extra printing):
17 ms to `main()`, 50 ms in `NSApplication.shared`, 35 ms to `applicationDidFinishLaunching`, 7 ms to create the core, painter and
shell, 27 ms to build the window, 16 ms to the first frame. Harf's own work is about 50 ms of that.

**The floor.** A minimal AppKit app (one window, one empty view, nothing else) built the same way reaches its first frame in
**123 to 139 ms, median 131 ms** on this machine. Harf (118 to 128 ms) is at that floor, not above it. **The 100 ms budget is
below what any AppKit window reaches here**, so it cannot be met by changes to Harf; it needs an owner decision (for example
"within 10 percent of an empty AppKit window", or a budget measured to a different moment). Not measured: a cold file cache
(needs `sudo purge`).

### Idle: budget about 0

`bench/idle.sh macos/.build/Harf.app 60`: window open at the prompt, 60 s sampled every 2 s: mean **0.01 percent**, max
0.20 percent, cumulative CPU time 0:00.15 to 0:00.16 (0.01 s in 60 s). `phys_footprint` 22 MB.
