# Phase 3, Slice 4: Conformance and Numbers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove Phase 3 is done by the design doc's own definition: real programs (vim, tmux, htop, less, fzf) work, `vttest` core screens are captured for the owner to review, and the numbers (footprint, throughput, keypress-to-pixel latency, startup, idle) are measured, recorded in `docs/perf.md` and compared with the brief's budgets. Fix what the measurements show is wrong; fix nothing before it is attributed.

**Architecture:** No new product features. New things are measurement and test tooling: a footprint script, a measurement mode in `--selftest`, program smoke tests that run real programs through `Session`, and a `--conformance <dir>` mode that drives `vttest` and saves a picture and the grid text of each screen. Fixes land where the measurements point (the view's backing surfaces, allocation sources, the PTY read path).

**Tech Stack:** Zig 0.17.1, Swift 6 / AppKit, libghostty-vt 1.0.1, `footprint` / `vmmap` / `sample` (macOS), and dev tools that stay out of the repo and the build: `vttest`, `tmux`, `htop` (Homebrew), `vtebench` (built from source in the scratchpad with the installed Rust toolchain).

**Spec:** `docs/superpowers/specs/2026-11-13-phase3-terminal-core-design.md` (slice 4: "`vttest` core cases, vim, tmux, htop, less, fzf; vtebench throughput and a keypress-to-pixel latency measurement in `docs/perf.md`; footprint at 700x420 pt with 1 MiB scrollback. Investigate the extra `IOSurface` seen in the spike app ... if the footprint is over target"; risks: memory budget, "vttest is interactive: results are recorded as a checklist with screenshots for you to review, not an automated pass"); `PROJECT_BRIEF.md` section 7 (budgets: idle CPU about 0, keypress to pixel under 10 ms, startup under 100 ms to first usable frame, 30 MB `phys_footprint`, throughput competitive) and Phase 3 of section 8; `docs/perf.md` (the footprint definition and earlier numbers).

## Global Constraints

- Zig **0.17.1** pinned. Tests: `.tools/zig/zig build test --summary all`; filter with `-Dtest-filter=<text>`. Benchmarks and measurements use a Release build via `macos/build-app.sh` (it now always relinks) or `-Doptimize=ReleaseFast`, and are gated behind `HARF_BENCH=1` or `HARF_MEASURE=1` so the normal suite stays fast.
- **Footprint definition** (from `docs/perf.md`, unchanged): `phys_footprint` from `footprint <pid>`, Release build, one window at **700x420 pt content**, measured 12 to 20 s after launch, Apple M1, macOS 27.0.1. The window size is part of the definition. Target: **30 MB**.
- A measurement tool starts the binary itself and tracks that pid. It never looks a process up by name and never kills one it did not start (this has already cost the owner a window once).
- Dev tools (`vttest`, `tmux`, `htop`, `vtebench`) are measurement tools, not project dependencies: not vendored, not in `build.zig`, not in `NOTICE`. Installing them on the owner's machine is a side effect: ask first (Task 0).
- No change to a locked decision in the brief (section 2) without asking. Idle cost zero: no timers or polling in product code.
- A claim about a number needs a before and after from the same harness, with machine, macOS version, date and commit, in `docs/perf.md`. A fix without a measurement that moved is not a fix.
- `include/harf.h` stays in sync with `src/capi.zig`; Swift never sees libghostty headers.
- No attribution trailers or AI mentions in commits, docs or code (user's global rule).

## Decisions (my calls, please check)

1. **Measure first, then fix.** Tasks 1 and 3 begin with attribution (where the 8 to 10 MB beyond the 28 MB spike and the 3 MB/s flood come from). A fix is chosen only after its cause is shown by a number, not by reading code.
2. **The 30 MB rule.** The target stays 30 MB at 700x420 pt with an empty session. Task 2 also records the reading with the scrollback full (1 MiB) and after a flood, because that is what daily use looks like. If the only way under 30 MB removes a feature, I stop and put the options with their numbers to you (smaller default scrollback, smaller default window, revising the target) instead of choosing.
3. **`vttest` core cases** are menus 1 (cursor movements), 2 (screen features), 3 (character sets), 6 (terminal reports), 8 (VT102 features) and 11 (non-VT100 tests). The output is one picture and one text dump per screen plus a checklist for you. It is a review aid, not a pass or fail.
4. **Program tests are smoke tests of observable outcomes** (a file's content after vim saves, the text of the grid, an exit status), run through `Session` with a real PTY. They skip with a clear message when the program is missing, so the suite stays green on a machine without them; after Task 0 they must run here.
5. **Latency is measured in-process:** from the key event's timestamp to the end of the draw that shows the echoed character, with the window off screen. It excludes the compositor and display scan-out (up to about one frame). The number is reported with that limit stated.
6. **Throughput** is reported as absolute numbers (MB/s for `cat` of a large file and for each `vtebench` benchmark), plus the ratio to the 186 to 448 MB/s parse-only spike figure. Comparing with other terminals needs installing them and is done only if you ask.

## Review Focus

Inputs the spec implies but a straightforward test would miss; each is pinned by a test or measurement in the named task.

1. **Chunk boundaries:** the same byte stream fed in chunks of 1, 7, 4096 and 65536 bytes produces an identical grid, including UTF-8 sequences, escape sequences and Arabic clusters split across chunks. The throughput fix may change read sizes, so this must be pinned before it (Task 3 `chunking does not change the grid`).
2. **Alternate screen exit:** leaving vim, less or tmux restores the primary screen exactly and leaves scrollback unpolluted; a crash-exit (kill -9 of the program) does not leave the terminal stuck in the alternate screen with mouse tracking on, once the shell redraws (Task 4 `program: alternate screen is restored`).
3. **Resize storm during a full-screen redraw:** repeated resizes while vim or tmux repaint end with a correct, stable grid and no crash (Task 4 `program: resize storm`).
4. **Footprint repeatability and state:** the settled reading agrees within 1 MB over three runs, and the state matters: empty, scrollback full, after a 100 MB flood. A flood must not leave memory growing without bound (Task 2 `footprint after a flood returns to the settled level`).
5. **Flood while the window is not drawing** (minimized or hidden): the output queue and the render path stay bounded; no growth beyond the scrollback cap (Task 3 `flood with no draws stays bounded`).

---

### Task 0: Tools and the baseline (needs your approval for the installs)

**Files:**
- Create: `bench/footprint.sh`, `docs/slice4-manual-check.md` (stub, filled in Task 7)
- Modify: `docs/perf.md`

**Interfaces:**
- Produces: `bench/footprint.sh [seconds=15] [mode=settled|scrollback|flood]`: launches `macos/.build/Harf.app/Contents/MacOS/Harf` itself with `HARF_CONTENT_SIZE=700x420`, tracks that pid, waits, prints `phys_footprint` and the `footprint -v` category breakdown (at least `IOSurface`, `Malloc Small`, `Malloc Metadata`, `Malloc Tiny`, `Malloc Large`, `CG image`, `Dirty` lines when present), and kills only that pid. `mode=scrollback` first makes the shell print enough lines to fill 1 MiB of scrollback (the script writes to the child through `HARF_CHILD_CMD`, a new test hook that replaces the login shell argv in `AppDelegate` with `/bin/sh -c "$HARF_CHILD_CMD; exec $SHELL"`); `mode=flood` prints 100 MB first.

- [ ] **Step 1: Ask you to approve** `brew install tmux htop vttest` (three small packages; `vtebench` is built from source in the scratchpad with the installed `cargo`, which needs network access to fetch it). Do nothing else in this task until you say yes. If you decline, tmux, htop and vttest tests and screens are recorded as not run and Tasks 4 and 5 shrink to vim, less and fzf.
- [ ] **Step 2: Write the failing check.** Run `bench/footprint.sh` (it does not exist yet). Expected: command not found.
- [ ] **Step 3: Implement** the script and the `HARF_CHILD_CMD` hook (the hook is read once at startup, only when the variable is set; no effect otherwise).
- [ ] **Step 4: Measure the baseline** three times per mode on the current `main` and record, in `docs/perf.md` under "Slice 4 baseline": the three readings, the category breakdown, machine, macOS, commit. Expected: settled about 38 to 40 MB (the earlier ad hoc reading); the breakdown shows where it sits.
- [ ] **Step 5: Run** the whole suite. Expected: pass.
- [ ] **Step 6: Commit** `bench: footprint script and slice 4 baseline`.

---

### Task 1: Where the memory goes (attribution only)

**Files:**
- Modify: `docs/perf.md`; throwaway instrumentation stays out of the commit.

**Interfaces:**
- Consumes: Task 0's script and breakdown.
- Produces: a table that attributes the settled footprint to causes, each with a number from an experiment, and a ranked list of candidate fixes.

- [ ] **Step 1: IOSurface.** Compare the settled footprint and the `IOSurface` line for: (a) the current view; (b) a build where `TerminalView` does not set a layer redraw policy or backing choice and the window uses an sRGB color space (`window.colorSpace = .sRGB`); (c) `layer.contentsFormat = .RGBA8Uint` if the default is wider; (d) a deliberately empty `NSView` of the same size (the prototype's 5 MB). Record each. The spike saw 9.2 MB against 5 MB in the prototype: say which setting accounts for the difference, or that none does.
- [ ] **Step 2: Malloc.** For the settled state, use `vmmap --summary`, `footprint -v` and `heap -s` on the pid to split `Malloc *` into: the libghostty terminal and render state (read `ghostty_terminal_get` `GHOSTTY_TERMINAL_DATA_MEMORY_USAGE`), the painter (four faces, glyph cache, fallback fonts, row cache), the Zig allocators, Swift/AppKit. Where one cause is over 2 MB, write the experiment that confirms it (for example, set the glyph cache cap and row cache cap to 0 in a scratch build and read the delta).
- [ ] **Step 3: Write** the attribution table and the ranked candidates into `docs/perf.md`. No product change in this task.
- [ ] **Step 4: Commit** `docs: slice 4 memory attribution`.

---

### Task 2: Reach 30 MB at 700x420 pt, or put the numbers to the owner

**Files:**
- Modify: whatever Task 1 names (expected: `macos/Sources/Harf/TerminalView.swift` or `App.swift` for the backing surface; `src/draw.zig`, `src/term.zig` or `src/vt.zig` for allocations); `docs/perf.md`.

**Interfaces:**
- Consumes: Task 1's ranked candidates.
- Produces: the settled footprint at or under 30 MB with an empty session; or, if not reachable without removing a feature, a recorded decision request.

- [ ] **Step 1: Write the failing check.** A `HARF_MEASURE=1` section in `--selftest` (or a test in `capi.zig`) that creates a session at 80x24, floods it with 100 MB through `Session`, and asserts the process's `phys_footprint` (read through `task_info` with `TASK_VM_INFO` in Swift) after a settle is within 2 MB of its value before the flood: `footprint after a flood returns to the settled level`. Run it first on the current build. Expected: pass or fail, recorded either way; if it fails that is a leak finding for this task.
- [ ] **Step 2: Apply the fixes in Task 1's order,** one at a time, re-measuring with `bench/footprint.sh` three times after each and keeping a fix only if the settled footprint dropped by more than the run-to-run spread. Record each attempt, kept or dropped, in `docs/perf.md`.
- [ ] **Step 3: Verify the whole state.** Settled, scrollback full, after a flood: three runs each, in `docs/perf.md`. Also run the whole suite, `macos/build-app.sh` and `Harf --selftest` (pictures regenerate byte-identical or the difference is explained).
- [ ] **Step 4: Decide.** Settled at or under 30 MB: done. Otherwise stop and write the options with numbers to the ledger and the final message (Decision 2). Do not pick one.
- [ ] **Step 5: Commit** `memory: <what moved>; footprint numbers`.

---

### Task 3: Throughput, from 3 MB/s to parse-bound

**Files:**
- Modify: `src/pty.zig`, `src/term.zig` (the read path), `docs/perf.md`; tests in `src/term.zig`.

**Interfaces:**
- Consumes: `Session` with a PTY, the existing flood benchmark in `src/capi.zig`.
- Produces: measured throughput for `cat` of a 100 MB text file and for the `vtebench` benchmarks, and a read path that is bound by parsing, not by per-read overhead.

- [ ] **Step 1: Pin the grid before touching the read path.** Write `chunking does not change the grid` (Review Focus 1): take a byte stream containing ASCII, 2-, 3- and 4-byte UTF-8, CSI and OSC sequences, Arabic with tashkeel and lam-alef, wide characters and a title change; feed it to `vt.Terminal.write` whole and in chunks of 1, 7, 4096 and 65536 bytes; assert identical row text, cursor, title and cell styles for every chunking. Expected: pass (the library owns chunking); this test protects the next steps.
- [ ] **Step 2: Attribute.** Build `vtebench` in the scratchpad (not in the repo). Run `cat` of a 100 MB file and `seq 1 3000000` with the `Session` benchmark, and sample the process with `sample <pid> 10` during a flood. Record where the time goes (the child's write rate through the PTY, `read` size and count, lock hold time, the poll loop, `requestWake`). Test these hypotheses, each with a measurement: (a) the kernel PTY buffer limits each `read` to a few KB so the per-read cost dominates; (b) the I/O thread parses under `term_lock` and the wake hops cost per read; (c) `seq` itself is slow to write through a PTY (compare to `dd if=/dev/zero | cat` through the same PTY and to Terminal.app's time for `seq 1 3000000 > /dev/null` through `script`).
- [ ] **Step 3: Write the failing test.** `flood throughput is not read-bound`: through `Session` with no callbacks, a child writing 64 MB of text in large blocks (`dd`-style) is fully parsed in at most N seconds, where N comes from Step 2 (a fraction of today's time chosen from the attribution; write the number into the test and the ledger). Run it. Expected: FAIL with today's time.
- [ ] **Step 4: Implement** the fix Step 2 named (for example: drain the PTY with repeated reads before taking the lock, one parse per batch, larger reads, wake once per batch). Keep `Review Focus 5`: `flood with no draws stays bounded`: a 100 MB flood with no wake handler leaves the process's footprint within the scrollback cap plus 2 MB.
- [ ] **Step 5: Run** the chunking test, the new tests, the whole suite and `Harf --selftest`. Expected: all pass.
- [ ] **Step 6: Record** `cat` and every `vtebench` number, before and after, in `docs/perf.md`, with the ratio to the 186 to 448 MB/s parse-only figure.
- [ ] **Step 7: Commit** `pty: <what changed>; throughput numbers`.

---

### Task 4: Real programs through a real PTY

**Files:**
- Create: `src/programs_test.zig` (tests only; imported from the `capi.zig` test block)
- Modify: `docs/slice4-manual-check.md`

**Interfaces:**
- Consumes: `Session.start/input/key/scroll/resize/mouse`, `vt.Terminal.rowText`, the programs found on `PATH`.
- Produces: tests named `program: <what>` that skip with a message if the program is missing.

- [ ] **Step 1: Write the failing tests** (they fail until the programs are installed or the behavior is right):
  - `program: vim edits and saves a file`: run `vim -u NONE -N <tmpfile>`, wait for the screen, send `ihello harf`, Escape, `:wq`, Enter; assert the file contains `hello harf` and the session exits with status 0.
  - `program: vim keeps its colors and mouse`: `vim -u NONE`, send `:syntax on`, `:set mouse=a`; assert a text cell with a non-default foreground appears for a keyword in a small file, and a wheel event moves the first visible line.
  - `program: alternate screen is restored` (Review Focus 2): a shell prints 3 marker lines, runs `vim -u NONE`, quits it; assert the three marker lines are on the screen again and `viewport().total` did not grow by vim's screens. Repeat with `less` and with `kill -9` of vim from the shell (after which the shell's next `printf '\033[?1049l\033[?1000l'` or `reset` is not needed for the markers to be readable once the prompt redraws).
  - `program: less pages and exits`: `less` on a 200-line file: space pages down (the first visible line number rises), `q` exits 0.
  - `program: fzf filters and selects`: pipe 100 lines into `fzf --height=100%`, type a filter, Enter; assert the selected line is printed.
  - `program: tmux splits and detaches` (skips without tmux): `tmux -f /dev/null new-session`, split with the prefix key, assert two panes' border characters on the grid, detach; the session exits cleanly.
  - `program: htop starts and quits` (skips without htop): wait for the word `CPU` or `Tasks` on the grid, send `q`, exit 0.
  - `program: resize storm` (Review Focus 3): while vim (and tmux if present) run, call `Session.resize` 200 times alternating between 60x20 and 140x50 with no pause, then settle at 100x30; assert no crash, the grid is 100x30, and the last row of vim's screen contains its status text.
- [ ] **Step 2: Run** `-Dtest-filter=program:`. Expected: the tests for installed programs run; any failure is a real finding. A failure that is a Harf bug is fixed in this task with its test as the RED (a vim redraw bug, a missing key encoding, a resize problem); a test that is wrong is fixed in the test and the reason is ledgered.
- [ ] **Step 3: Pictures.** With the PNG hook, save one picture each of vim (with syntax colors), tmux (two panes), htop and fzf running in the view. Read them yourself, note in the ledger what you see (borders, colors, line-drawing characters, the cursor), and save them under `docs/slice4/`. Do not claim they look right.
- [ ] **Step 4: Run** the whole suite and `Harf --selftest`. Expected: pass.
- [ ] **Step 5: Commit** `tests: real programs through a PTY`.

---

### Task 5: `vttest` screens for the owner

**Files:**
- Modify: `macos/Sources/Harf/main.swift` (a `--conformance <dir>` mode), `include/harf.h` only if a new call is needed
- Create: `docs/conformance/vttest.md`, `docs/conformance/` pictures and text dumps

**Interfaces:**
- Consumes: the installed `vttest`, `TerminalController`, `rowText`, the view's bitmap capture.
- Produces: `Harf --conformance <dir>` writes, for each captured screen, `NN-<menu>-<screen>.png` and `.txt` (the grid text), and a `README` listing them in order; `docs/conformance/vttest.md` is the owner's checklist: one line per screen with what a correct screen looks like (from vttest's own description printed on screen) and a column for the owner's verdict.

- [ ] **Step 1: Write the failing check.** `Harf --conformance <tmp>` with vttest installed must produce at least one picture and one dump for menu 1 and exit 0. Run it before the mode exists. Expected: the option is not recognized.
- [ ] **Step 2: Implement** the mode: for each of menus 1, 2, 3, 6, 8 and 11, start `vttest` in a 80x24 view, send the menu choice and Return, wait for the screen to settle (no output for 300 ms), save the picture and dump, send Return to advance to the next screen of that test, and repeat until the menu returns; then quit. A screen that needs input vttest cannot take from a script (for example tests that wait for a reply typed by the user) is recorded as `needs a human` in the checklist, not skipped silently.
- [ ] **Step 3: Run it** and read every picture and dump. In `docs/conformance/vttest.md` write what I observe against what vttest says should be there (for example the frame of E characters, wrap behavior, tab stops, 132-column mode, double-height lines, line-drawing set, terminal reports): a line per screen, `matches`, `differs: <how>` or `cannot tell`. Do not mark the screens right on the owner's behalf; the owner's column stays empty.
- [ ] **Step 4: For each `differs`** decide whether it is Harf's drawing, input or resize code (a Harf bug: fix it with a test as RED) or the library's behavior (record it as a library finding with the exact sequence). Features that are out of v1 scope (for example double-width or double-height line attributes if the painter does not draw them) are listed in the checklist as known gaps with a ruling, not fixed here.
- [ ] **Step 5: Run** the whole suite and `Harf --selftest`. Expected: pass.
- [ ] **Step 6: Commit** `conformance: vttest screens and owner checklist`.

---

### Task 6: Latency, startup and idle against the budgets

**Files:**
- Modify: `macos/Sources/Harf/main.swift` (a `HARF_MEASURE=1` section), `macos/Sources/Harf/App.swift` (a startup trace behind `HARF_TRACE=startup`), `docs/perf.md`

**Interfaces:**
- Produces: printed measurements: keypress-to-draw latency (median, p95, max over at least 200 keystrokes at an idle prompt and during a flood), startup time to the first drawn frame, idle CPU.

- [ ] **Step 1: Write the failing check.** A `HARF_MEASURE=1` section that types 200 characters through real key `NSEvent`s into a `cat` child in an off-screen window, timing each from the event's `timestamp` (system uptime) to the end of the `draw(_:)` that first shows its echo, using `displayIfNeeded()` on the wake. It asserts the median is under 10 ms (the budget). Run it. Expected: it reports a number; record whether it passes. A failure is a finding with a profile (`sample`), not a reason to loosen the assertion.
- [ ] **Step 2: Startup.** `HARF_TRACE=startup` prints the time from process start (`ProcessInfo` start time via `sysctl` `kern.proc.pid`) to the end of the first draw. Run it ten times from a cold file cache and a warm one; record median and worst. Budget: under 100 ms to the first usable frame.
- [ ] **Step 3: Idle.** Use `bench/footprint.sh`'s own-pid pattern for 60 seconds at the prompt: mean and max CPU and cumulative CPU time. Budget: about 0.
- [ ] **Step 4: If a budget fails,** profile (`sample`, Instruments) and fix the largest cost with its test as the RED, or record the options for the owner. Record before and after.
- [ ] **Step 5: Record** all three in `docs/perf.md` with what each excludes (compositor, display scan-out, the shell's own startup).
- [ ] **Step 6: Commit** `perf: latency, startup and idle against the budgets`.

---

### Task 7: Close Phase 3 against its definition

**Files:**
- Modify: `docs/perf.md`, `ARCHITECTURE.md`, `docs/slice4-manual-check.md`
- Create: `docs/phase3-done.md`

**Interfaces:**
- Produces: one page that states Phase 3's "done when" line by line with its evidence.

- [ ] **Step 1: Write `docs/phase3-done.md`:** each clause of the design doc's "Done when" (zsh runs; core `vttest` cases pass; vim, tmux, htop, less and fzf work; idle and memory budgets hold; throughput and latency recorded) with: the evidence (test names, picture paths, numbers), what the owner still has to judge, and any clause that is not met, plainly.
- [ ] **Step 2: Fill `docs/slice4-manual-check.md`** for the owner: use vim, tmux, htop, less and fzf for a few minutes each in the real app (typing, resize, mouse, copy, colors, Arabic text in each); review `docs/conformance/vttest.md`; leave the app idle for a minute; check the footprint with `bench/footprint.sh`.
- [ ] **Step 3: `ARCHITECTURE.md` row** for slice 4: what moved (memory, throughput), what was measured, open items and owner decisions.
- [ ] **Step 4: Run** the whole suite, `macos/build-app.sh` and `Harf --selftest`. Expected: pass.
- [ ] **Step 5: Commit** `slice 4: Phase 3 done-when evidence, owner checklist`.

---

## Self-review

- Spec coverage (slice 4 line): `vttest` core cases Task 5; vim, tmux, htop, less, fzf Task 4; `vtebench` throughput Task 3; keypress-to-pixel latency Task 6; footprint at 700x420 pt with 1 MiB scrollback Tasks 0 to 2; the extra `IOSurface` investigation Task 1 step 1; results recorded in `docs/perf.md` throughout; the brief's startup and idle budgets Task 6; Phase 3's "done when" Task 7. Risks from the design doc: memory (Tasks 1 and 2), vttest being interactive (Task 5, a checklist not an automated pass), dev tools out of the repo (Global Constraints, Task 0).
- Not covered on purpose: comparing with other terminals (only if the owner asks); the brief's Phase 5 agent-compatibility work; kitty graphics; selection autoscroll; OSC 133/8/52; the open owner decisions from the follow-ups plan (P2 deadline, P3 dirty rows, R7, R8), which are independent of this slice.
- The weak spots: Task 2's outcome depends on what Task 1 finds and may end as a decision for the owner, not a fix; Task 3's test threshold is set from the attribution, so it cannot be written before Step 2; vttest screens that need typed replies are recorded as human-only; the latency number excludes the compositor.
- Types and names used across tasks: `bench/footprint.sh`, `HARF_CHILD_CMD`, `HARF_MEASURE`, `HARF_TRACE=startup`, `--conformance <dir>`, and the test names in Review Focus appear once in Interfaces and are used unchanged.
