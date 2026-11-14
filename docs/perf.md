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
