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

## Budget status

- **Idle RSS (brief: under 30 MB): not attainable as stated.** The empty AppKit + Metal window alone is 64-67 MB RSS, because RSS counts shared system-framework pages.
- **Use `phys_footprint` as the budget metric** (what Activity Monitor calls Memory). Baseline is 26 MB (peak 30 MB), so the original 30 MB figure leaves only ~4 MB for scrollback, atlas and the shell session.
- **Proposed revision (needs owner confirmation):** idle phys_footprint of an empty shell session under about 40 MB, tracked as baseline + delta; keep RSS as a secondary number only. This 40 MB figure is my proposal, not a measured fact.
- Idle CPU budget (~0%) is met by the baseline: 0.01% mean.
