# Phase 3 against its definition of done (2026-11-14)

The design doc (`docs/superpowers/specs/2026-11-13-phase3-terminal-core-design.md`) says Phase 3 is done when: "a daily-usable plain
terminal. Concretely: zsh runs; core `vttest` cases pass; vim, tmux, htop, less and fzf work; the idle and memory budgets still
hold; throughput and latency are recorded in `docs/perf.md`." Each clause with its evidence, what only the owner can judge, and
what is not met. Numbers are in `docs/perf.md` (sections "Slice 4 ...").

| Clause | Status | Evidence | Still yours to judge |
|---|---|---|---|
| zsh runs | **Met** | The app opens a window with the login shell (`TerminalView`, self-test, daily use in slices 2 and 3: colors, scrollback, mouse, selection, Arabic). | Feel (typing, scrolling, resize). |
| Core `vttest` cases pass | **Not decidable by me** | `Harf --conformance <dir>` captured 93 screens of menus 1, 2, 3, 6, 8 and 11 (`docs/conformance/`). I read 6 pictures and 5 text dumps: cursor movement, graphic rendition, character sets, the 64-color matrix and the device reports behave as vttest describes. Findings: **F1** 132-column mode changes the grid but not the view (clipped), **F2** DECREQTPARM unanswered (library), **F3** blink steady (decision), **F4** DEC alternate ROM sets show ASCII. | The checklist `docs/conformance/vttest.md`: every Owner cell is empty. 7 screens need a human and 151 deeper menu paths were not walked. |
| vim, tmux, htop, less and fzf work | **Met by smoke tests; looks are yours** | `src/programs_test.zig`, 8 tests plus a safety test: vim edits and saves, shows syntax colors and takes the mouse wheel, the alternate screen is restored after vim and less, and after a SIGKILLed vim once the shell resets the terminal (before the reset the test asserts vim holds the alternate screen and mouse reporting; after it, that both are off; no terminal does this by itself after a SIGKILL), less pages, fzf filters and selects, tmux splits and detaches, htop starts and quits, a 200-resize storm during a vim repaint ends with a correct grid. Pictures: `docs/slice4/`. | Using each for a few minutes in the real app (`docs/slice4-manual-check.md`). |
| Idle budget holds | **Met** | 60 s at the prompt: 0.01% mean CPU, 0.20% max, 0.01 s CPU in 60 s. | |
| Memory budget holds (30 MB `phys_footprint` at 700x420 pt) | **Met when measured, not in another machine state: open** | 25 MB settled, 26 MB with the scrollback full, 26 MB after a 100 MB flood (nine runs); before the sRGB window color space fix the active states were 32 to 34 MB. But the **same binary later read 29 to 39 MB** settled with a second (4K) display online: about 5 MB of window surface accounted as "owned, unmapped" plus 2.6 MB more graphics memory. Cause unconfirmed (see `docs/perf.md`, "Footprint depends on the machine's graphics state"). | Whether the external display was connected during the 25 to 26 MB runs, and what the target should mean when graphics accounting moves it by about 10 MB. |
| Throughput recorded | **Met** | `docs/perf.md`: the load is bound by the PTY and the child's writes, not by Harf (a bare reader takes the same time); `vtebench` 0.3.1: 10 to 50 ms per 1 MiB sample in the app. | Whether "competitive" holds against other terminals: not compared (needs them installed). |
| Latency recorded | **Recorded; the pixel-level budget is undecided** | Keypress to draw at an idle prompt through the product's wake path: median about 3.9 ms, p95 about 4.8 ms, max about 6 ms, in process. Adding the display's average refresh wait (about 8 ms at 60 Hz) gives about 12 ms, over the 10 ms budget; the budget needs a definition. | Typing feel; what the budget measures. |

## Not met, or open

- **Startup budget (under 100 ms to the first usable frame): not met, and not reachable by Harf's code.** Harf takes about
  122 ms warm; an empty AppKit window with one empty view takes about 131 ms on this machine. Needs your decision: restate the
  budget relative to the AppKit floor, or measure to a different moment.
- **Footprint is state-dependent** (see the memory row): the 30 MB target holds in one machine state and not in another.
- **F1, the 132-column switch,** is fixed: the window (or, in the conformance run, the view) is resized to fit the grid when a program switches it, and back (self-test 1j). The conformance pictures in `docs/conformance/` were captured before this and show those screens clipped at 80 columns.
- **Flood latency** (typing during heavy output) and **cold-cache startup** were not measured.
- Decisions carried over from the follow-ups plan are closed (ARCHITECTURE.md, 2026-11-14 "Open decisions closed"): P2 1 s deadline, P3 dirty rows (built after being measured as small; see perf.md), R7 mode 1007 honored, R8 word and line drag built.
- Changes made in this slice because a measurement said so: the window's color space is sRGB (one backing surface instead of
  two); `build-app.sh` always relinks; `bench/idle.sh` tracks its own pid; new `bench/footprint.sh` and `bench/startup.sh`.
