# Harf vs Terminal.app benchmark

Date: 2026-11-17 · macOS 24.6.0 (Darwin) · Harf 0.3.3 (fresh instance via `open -n -a Harf`) · single run each, AC power.
Reproduce: run `bench/bench.sh <Label>` inside each terminal. Raw output: `bench-Terminal.txt`, `bench-Harf.txt`.

| Metric | Terminal.app | Harf | Result |
|---|---|---|---|
| Idle RAM (footprint) | 62 MB | 47 MB | Harf 24% lower |
| RAM after load | 86 MB | 77 MB | Harf 10% lower |
| RAM after settling | 78 MB | 65 MB | Harf 17% lower |
| `seq 1 2000000` | 2.50 s | 3.13 s | Harf 25% slower |
| `cat` 50 MB text | 1.54 s | 1.76 s | Harf 14% slower |
| 20k ANSI colour lines | 0.07 s | 0.08 s | same |
| App CPU seconds during load | 4.32 | 5.08 | Harf 18% higher |
| Idle CPU over 20 s | 1.00% | 0.15% | noisy (earlier run: 0.45% vs 1.00%) |

## Long-running instance (before benchmark)
Harf PID 18526, up 22h, 4 Claude Code sessions: footprint 173–215 MB (82 MB IOSurface/GPU buffers), 0–4% CPU, 10 threads, energy score 3.5–4 when streaming, ~0 idle.
The 4 Claude instances + helpers under it used ~2.4 GB RSS; Harf itself is <8% of that.

## Takeaways
- Memory: Harf lighter than Terminal.app in a fresh state; grows with long sessions (scrollback, GPU surfaces).
- Throughput: Harf trails on heavy output (+14–25% time, +18% CPU). Colour parsing is not the bottleneck.
- Idle CPU: single samples are noisy; repeat before concluding.
- Not measured: input latency, battery drain on DC power, multi-run variance.

## Profile of `seq 1 2000000` (macOS `sample`, 2 s, fresh instance) — `bench/profile-seq.txt`, `bench/profile-seq.sh`
Per-thread samples out of 1374 (2 s at 1 ms):

- **Main thread: ~1030 (75%)** in `TerminalController.invalidateChangedRows` -> `harf_term_dirty_rows` (`capi.zig:255`).
  That call holds the session lock and, for every visible row, runs `Painter.gather` (`draw.zig:400`: one `cellInRow` -> `readCell` -> `ghostty_render_state_row_cells_get` C-API call per column) and then `rowHash` (Wyhash) to see whether the row changed.
  Top self-time frames: `Wyhash.update` 324, `ghostty_render_state_row_cells_get` 262, `readCell` 162, `Painter.gather` 60, `rowHash` 58.
- **PTY/parser thread: 1012 (74%) blocked in `__psynch_mutexwait`** — waiting for that same session lock. Actual parsing (`ghostty_terminal_vt_write`) is only ~31 samples (2%).
- Render/GPU threads: idle.

Conclusion: the extra CPU/time versus Terminal.app is not parsing or drawing. It is change detection: every frame re-reads and re-hashes the whole visible grid cell by cell under the session lock, which also stalls the parser thread. The gap grows with window size.

Candidate fixes (not applied): use ghostty's per-row dirty flags from the render state to skip unchanged rows instead of hashing all of them; hash only rows flagged dirty; shorten the lock (copy then hash outside it); coalesce frames while output is flooding.
