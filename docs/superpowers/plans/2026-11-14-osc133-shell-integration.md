# OSC 133 Shell Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harf understands OSC 133 prompt marks: Cmd+Up/Down jump between prompts, Cmd+Shift+A selects the last command's output, a tab shows when a command is running, and a long command that finishes in the background posts a notification. zsh gets the marks automatically.

**Architecture:** libghostty-vt already parses OSC 133 and keeps per-row and per-cell prompt state. It also has `ghostty_terminal_scroll_viewport(DELTA_PROMPT)`, `ghostty_terminal_select_output` and a `GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT` callback (exit code included). So Zig only wraps those in `src/vt.zig`, `Session` and `capi.zig`; Swift adds actions and a status marker. The one piece of real work is making a shell emit the marks: a bundled `ZDOTDIR` shim for zsh (the macOS default shell).

**Tech Stack:** Zig 0.17.1 (`.tools/zig`), libghostty-vt 1.4.1-dev (vendored in `zig-pkg/`), Swift/AppKit.

**Spec:** `PROJECT_BRIEF.md` §6 (OSC 133 bullet, per-tab status, Cmd+Up/Down) and `zig-pkg/ghostty-*/include/ghostty/vt/{terminal.h,selection.h}` (semantic prompt section).

## Global Constraints

- Add capability in Zig, not Swift; `include/harf.h` is hand-written and mirrors `src/capi.zig` (ARCHITECTURE.md).
- Session callbacks run on the I/O thread: quick, no calls back into the session (`src/term.zig` header). Swift hops to main like the existing callbacks.
- No timers while idle (brief §3.2): a command's duration is a monotonic timestamp difference at its end, never a polling timer.
- A program's text is untrusted: the command line and error text OSC 133 carries are never shown or stored.
- Run Zig with `PATH=$PWD/.tools/zig:$PATH`; build the app with `macos/build-app.sh`; app self-test is `macos/.build/Harf.app/Contents/MacOS/Harf --selftest`.
- Commit messages carry no attribution lines (user rule).

## Decisions made by default (change any of them before the task that uses it: 1 and 2 in Task 4, 3 and 4 in Tasks 5 and 4)

1. zsh integration is **on by default** (`shell_integration = auto`; `off` disables). It sets `ZDOTDIR` for the login zsh Harf starts. bash and fish get nothing in this plan.
2. The shim emits `A` (prompt start), `C` (output start) and `D;<exit>` (command end), and **not `B`**: nothing here needs the input region, and a `B` inside `PS1` is fragile with prompt frameworks. Phase 4's input-region typing adds it.
3. "Finished in the background" means a command that ran at least **10 seconds** and ended while its pane did not have the keyboard. Fixed, no setting.
4. `exec ...` at the prompt does not emit `C`, so `exec zsh` does not leave a tab stuck "running" (the new shell has no integration; a new tab does).

## Review Focus

- A shell or program that never emits OSC 133 (bash, ssh, `seq`): Cmd+Up/Down and Cmd+Shift+A do nothing, no marker, no error. Pinned in Tasks 2 and 3.
- The alternate screen (vim, less): the prompt and output actions return false so the key still reaches the program. Tasks 2 and 3.
- A program printing thousands of OSC 133 sequences (`cat` of a hostile file): at most one callback per running/idle change, never one per sequence. Task 1.
- The user's own `ZDOTDIR` (or none, or no `.zshenv`): their files still load and `$ZDOTDIR` is theirs again inside the shell. Task 4.
- Output that has scrolled out of the scrollback, or `Cmd+K` just cleared everything: selection and jump do nothing or select only what survives, never a wrong range. Tasks 2 and 3.

---

### Task 1: Command state from OSC 133

**Files:**
- Modify: `src/vt.zig` (a `command` callback next to `bell`, registered with `GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT` like `titleTrampoline`), `src/term.zig`, `src/capi.zig`, `include/harf.h`, `macos/Sources/Harf/TerminalView.swift` (pass `command: nil` until Task 5 so the build stays green)
- Test: `src/term.zig`

**Interfaces:**
- Produces: `vt.Callbacks.command: ?*const fn (ctx: ?*anyopaque, kind: CommandKind, exit_code: ?i32) void` with `pub const CommandKind = enum { prompt_start, input_start, output_start, command_end }`.
- Produces: `term.Callbacks.command: ?*const fn (ctx: ?*anyopaque, running: bool, exit_code: ?i32, duration_ms: u32) void`, called only when the state changes: `output_start` makes it running (duration 0); `command_end` while running makes it idle (duration since `output_start`, saturating at `u32` max). `prompt_start` while running also ends it, with no exit code.
- Produces: C `void (*command)(void *ctx, int running, int exit_code, int has_exit_code, uint32_t duration_ms)` as the last field of `HarfTermCallbacks`.

- [ ] **Step 1: Write the failing test** `test "command callbacks: C starts, D ends with the exit code, repeated marks make no event"` in `src/term.zig`, using the Spy pattern the other callback tests use. Script: `printf '\033]133;A\007\033]133;A\007'; printf '\033]133;C\007'; sleep 0.3; printf '\033]133;D;3\007'; i=0; while [ $i -lt 1000 ]; do printf '\033]133;A\007'; i=$((i+1)); done; sleep 5`. Assert the spy saw exactly two events: `(running = true)`, then `(running = false, exit_code = 3, duration_ms >= 250)`.
- [ ] **Step 2: Run it, expect FAIL.** `PATH=$PWD/.tools/zig:$PATH zig build test -Dtest-filter="command callbacks"` fails to compile (no `command` field).
- [ ] **Step 3: Implement** the vt trampoline and the `Session` state (an atomic or lock-held `running` flag and an `output_start` timestamp from `std.time` monotonic clock), the capi pass-through and the header field.
- [ ] **Step 4: Run the test, expect PASS,** then the full `zig build test` (still 247 passed, 4 skipped plus the new one) and `macos/build-app.sh`.
- [ ] **Step 5: Commit** `Command state from OSC 133: one callback per running/idle change, with exit code and duration`.

### Task 2: Cmd+Up / Cmd+Down jump between prompts

**Files:**
- Modify: `src/vt.zig`, `src/term.zig`, `src/capi.zig`, `include/harf.h`, `src/config.zig` (`prev_prompt`, `next_prompt` actions, default `cmd+up`, `cmd+down`, the actions comment), `macos/Sources/Harf/TerminalView.swift` (`perform`)
- Test: `src/vt.zig`, `src/config.zig`

**Interfaces:**
- Produces: `vt.Terminal.scrollPrompt(self, delta: i32) bool` using `GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT`; true only if the viewport offset changed and the terminal is not on the alternate screen.
- Produces: `Session.scrollPrompt(delta: i32) bool` (locks, then `requestWake`); C `int harf_term_scroll_prompt(HarfTerm *t, int delta)` (1 moved, 0 not).
- Swift `perform`: `case "prev_prompt": return harf_term_scroll_prompt(t, -1) == 1`, and `next_prompt` with `1`. Returning false lets the key fall through, as `clear_view` does.

- [ ] **Step 1: Write the failing tests** in `src/vt.zig`: `test "scrollPrompt moves the viewport one prompt at a time"` feeds three blocks of `A`, `$ `, `C`, `seq 1 40`, `D;0` then a last `A` and `$ `. Assert `scrollPrompt(-1)` is true and `rowText(0)` starts with `$ `, a second `-1` moves up again, `+1` moves back down, and at the first prompt `-1` returns false. `test "scrollPrompt does nothing without marks or on the alternate screen"`: `seq 1 100` then `scrollPrompt(-1)` is false and the offset is unchanged; the same after `\x1b[?1049h`. In `src/config.zig` extend the defaults test: `cmd+up` is `prev_prompt`, `cmd+down` is `next_prompt`.
- [ ] **Step 2: Run, expect FAIL** (`-Dtest-filter="scrollPrompt"`).
- [ ] **Step 3: Implement** the four layers above.
- [ ] **Step 4: Run the filtered tests and the full suite, expect PASS;** run `macos/build-app.sh` and the self-test.
- [ ] **Step 5: Commit** `Cmd+Up and Cmd+Down jump between prompts (OSC 133); the key goes to the program on the alternate screen`.

### Task 3: Cmd+Shift+A selects the last command's output

**Files:**
- Modify: `src/vt.zig`, `src/term.zig`, `src/capi.zig`, `include/harf.h`, `src/config.zig` (`select_output`, default `cmd+shift+a`), `TerminalView.swift`
- Test: `src/vt.zig`, `src/config.zig`

**Interfaces:**
- Produces: `vt.Terminal.selectLastOutput(self) bool`: takes the grid ref of the row just above the prompt the cursor is on (walk up from the cursor row with `GHOSTTY_ROW_DATA_SEMANTIC_PROMPT` until a prompt row; none found means false), calls `ghostty_terminal_select_output`, installs the result with `setSelection`. False on `GHOSTTY_NO_VALUE`, with no marks, and on the alternate screen.
- Produces: `Session.selectOutput() bool` (locks, wake), C `int harf_term_select_output(HarfTerm *t)`, Swift `case "select_output": return harf_term_select_output(t) == 1`. Cmd+C then copies it (the selection is the terminal's own).

- [ ] **Step 1: Write the failing tests** in `src/vt.zig`: `test "selectLastOutput selects the output of the last finished command"`: block one prints `alpha`, `beta`; block two prints `gamma`, `delta`, each wrapped in `A`/`C`/`D;0`, ending at a fresh prompt. After it `selectionText` equals `"gamma\ndelta"`. `test "selectLastOutput does nothing without marks or on the alternate screen"`: false, `selectionText` returns `error.NoSelection`. `test "selectLastOutput after the scrollback was cleared"`: write the blocks, then `\x1b[H\x1b[2J\x1b[3J`, expect false. Config defaults test: `cmd+shift+a` is `select_output`.
- [ ] **Step 2: Run, expect FAIL** (`-Dtest-filter="selectLastOutput"`).
- [ ] **Step 3: Implement.** If libghostty selects only the surviving part of output that has scrolled out, accept it and say so in the decision log; do not write range logic of our own.
- [ ] **Step 4: Run the filtered tests, the full suite, the app build and self-test, expect PASS.**
- [ ] **Step 5: Commit** `Cmd+Shift+A selects the last command's output (OSC 133)`.

### Task 4: zsh emits the marks (shell integration)

**Files:**
- Create: `macos/shell-integration/zsh/.zshenv`
- Modify: `macos/build-app.sh` (copy `macos/shell-integration` to `$APP/Contents/Resources/shell-integration`), `src/pty.zig` (`Pty.Options.shell_integration_dir: ?[:0]const u8 = null`; `buildEnv` takes it), `src/term.zig` (`Options.shell_integration_dir`, passed through), `src/capi.zig` + `include/harf.h` (`void harf_set_shell_integration_dir(const char *dir)`, NULL clears; a process-wide default that `spawnShell` uses, `// ponytail: global, per-window setting if it ever needs one`), `src/config.zig` (`shell_integration = auto|off`, `harf_config_shell_integration`, mirror `notifications`; add the key to the generated config comments and the keys list in the config test), `macos/Sources/Harf/Settings.swift` (on load and reload: `auto` sets the dir to the bundle's `Resources/shell-integration` if it exists, `off` sets NULL)
- Test: `src/term.zig` (real zsh), `src/config.zig`

**Interfaces:**
- Consumes: Task 1's `Callbacks.command`.
- Produces: when `shell_integration_dir` is set and the shell is zsh, the child gets `ZDOTDIR=<dir>/zsh`, `HARF_ORIG_ZDOTDIR=<previous ZDOTDIR, or empty>` and `HARF_SHELL_INTEGRATION=1`. Any other shell, and any `argv` that is not the login shell, is untouched.
- `.zshenv` behavior: restore `ZDOTDIR` from `HARF_ORIG_ZDOTDIR` (unset it when that was empty) and unset the two `HARF_` variables; source the user's `${ZDOTDIR:-$HOME}/.zshenv` if present; if the shell is interactive, register `precmd` (`\e]133;D;$?\a` except before the first prompt, then `\e]133;A\a`) and `preexec` (`\e]133;C\a`, skipped when the command line starts with `exec`) through `add-zsh-hook`, once (guard variable). Write it from the spec above, in its own words.

- [ ] **Step 1: Write the failing test** `test "zsh with the integration reports commands and keeps the user's ZDOTDIR"` in `src/term.zig`: make a temp directory, `setenv("ZDOTDIR", tmp, 1)` (tests run serially; unset it at the end), start `Session` with `argv = {"/bin/zsh", "-i"}` and `shell_integration_dir = "macos/shell-integration"` (the path the test runs from; use the same resolution the other file-reading tests use). Wait for the prompt, type `false\n`: the spy sees `running` then `idle, exit_code 1`; type `true\n`: `idle, exit_code 0`; type `print -r -- "Z=$ZDOTDIR"\n` and expect a row containing `Z=` followed by the temp path. A second case with no `ZDOTDIR` set expects `Z=` followed by nothing. Config test: `shell_integration = off` parses, the default is auto.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the env change, the options plumbing, the config key and the shim; copy the directory in `build-app.sh`.
- [ ] **Step 4: Run the filtered test and the full suite, expect PASS.** Run `macos/build-app.sh`, confirm `macos/.build/Harf.app/Contents/Resources/shell-integration/zsh/.zshenv` exists, and run the self-test.
- [ ] **Step 5: Commit** `zsh shell integration: a bundled ZDOTDIR shim emits OSC 133 prompt, output and exit marks; shell_integration = auto|off`.

### Task 5: Running marker on the tab, finished-in-background notification, docs

**Files:**
- Modify: `macos/Sources/Harf/TerminalView.swift` (a `commandCallback` that hops to main like `bellCallback`; `TerminalController.onCommand: (_ running: Bool, _ exitCode: Int32?, _ durationMs: UInt32) -> Void`), `macos/Sources/Harf/Panes.swift` (per-pane `running`; the native tab's title, `window.tab.title`, gets the prefix `"● "` while any pane of the window is running; the title bar keeps the plain title), `macos/Sources/Harf/App.swift` (the single-window path), `macos/Sources/Harf/main.swift` (self-test), `docs/phase6-manual-check.md`, `ARCHITECTURE.md`
- Test: `macos/Sources/Harf/main.swift` self-test

**Interfaces:**
- Consumes: Task 1's C callback and Task 4's integration.
- Notification rule, in `Panes.swift` where `onNotify` is wired: on `running == false` with `durationMs >= 10_000`, call `Notifier.post(title: "Command finished", body: exitCode == nil || exitCode == 0 ? "Done" : "Failed (exit \(exitCode!))", focused: c.hasKeyboard())`. The existing policy (`notifications = unfocused|always|off`) applies; the command text is never used.

- [ ] **Step 1: Write the failing self-test** in `main.swift`: a controller running `/bin/sh -c "printf '\033]133;C\007'; sleep 0.3; printf '\033]133;D;3\007'; sleep 5"`; after a pump, `onCommand` was called with `running == true`, then with `running == false`, `exitCode == 3`, `durationMs >= 250`.
- [ ] **Step 2: Run the self-test, expect FAIL** (no `onCommand`).
- [ ] **Step 3: Implement** the callback, the tab prefix and the notification rule. Keep tab title and window title updates in one function so a program's title change does not drop the prefix.
- [ ] **Step 4: Docs.** In `docs/phase6-manual-check.md` add a "Shell integration" section: `Cmd+Up/Down` in a zsh tab with several commands; `Cmd+Shift+A` then `Cmd+C` and paste; `sleep 12` in a background tab shows `●` and posts "Command finished" when it ends (**the owner could not see a notification on screen earlier; say if this one fails too**); `exec zsh` does not leave `●`; `shell_integration = off` and a new tab: no marks; bash gets nothing. In `ARCHITECTURE.md` add one decision-log row covering the four decisions above and what libghostty provides.
- [ ] **Step 5: Run the full suite, `macos/build-app.sh`, the self-test, expect PASS. Commit** `Tab shows a running command; a long command that finishes in the background posts a notification; checklist and decision log`.

---

## Not in this plan

- **Marking failed commands** (brief §6): the library keeps no exit code per row, so it needs tracked grid refs (`grid_ref_tracked.h`) plus a painter change. A separate slice after this one.
- **"Waiting for input / asks for approval"** status: no OSC 133 signal exists for it; programs' own OSC 9 notifications already reach the user.
- bash and fish integration, `133;B` and the Arabic input region (Phase 4/7), Option-click cursor moves.
