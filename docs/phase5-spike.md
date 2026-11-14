# Phase 5 spike: Claude Code and Codex in Harf (2026-11-14)

Brief section 8, Phase 5: "Claude Code and Codex run without flicker or layout bugs, including with Arabic content." This is
the first look, not the acceptance. Claude Code 2.1.325 and Codex CLI 0.163.0, run on a 100x32 grid (and 70x22, 72x24, 120x40),
Harf at `p3-dirty-rows` merged (868f81f). No model turn was run: nothing was submitted to either program.

## How it was done

`tools/agent-proxy.py` runs the program on an inner PTY inside a real Harf `Session` and logs every chunk the program wrote
("OUT": its queries and drawing) and every byte Harf sent back ("IN": replies and keys). `src/agents_spike_test.zig` starts it
and follows a scripted list of steps (`wait`, `waitfor`, `text`, `shift-enter`, `paste`, `resize`, `ctrl-c`, `dump`, `shot`).
`dump` prints the screen text and the modes the program set; `shot` draws the grid with the window's own `Painter` and
`tools/raw2png.py` makes the picture. Gated on `HARF_AGENT_CMD`, so the normal suite skips it.

```sh
HARF_AGENT_CMD="claude" HARF_PROXY_LOG=/tmp/claude.log \
  HARF_AGENT_SCRIPT="waitfor:Try;text:hello;shift-enter;text:second;dump;shot:/tmp/c.raw" \
  zig build test -Dtest-filter="agent spike: run the program in HARF_AGENT_CMD through the proxy and follow HARF_AGENT_SCRIPT"
python3 -I tools/raw2png.py /tmp/c.raw /tmp/c.png
```

Two traps: Zig caches a test run by its binary, not its environment, so a run with a new script can print nothing (change the
filter's length to force a new run); and `zig build test` sets `NO_COLOR` for what it runs, which made Claude Code draw
without color until the proxy dropped it. A real Harf window never sets `NO_COLOR`.

## Claude Code 2.1.325

**Works** (evidence: dumps, `claude*.log`, pictures in `docs/phase5/`):

- It starts, draws and takes input. Picture `claude-start.png`: logo in its orange, bold, green `/rc`, the footer in yellow.
- Startup queries, all answered by Harf: XTVERSION (`CSI > 0 q`), kitty keyboard query (`CSI ? u`, answered 0), DA1 (`CSI c`,
  `?62;22c`, asked twice, the second as the end marker of the batch), DECRQM for 2026 and 1016 (`2`: known, off).
- Modes it sets, all honored: alternate screen (1049), mouse 1000/1002/1003/1006, bracketed paste, focus events (1004),
  synchronized output (2026 around every frame), kitty keyboard flags 5 (`CSI > 5 u`), modifyOtherKeys 2 (`CSI > 4;2 m`).
- Keys: Shift+Enter reaches it as `CSI 13;2 u` and inserts a newline; Ctrl-C arrives as `CSI 99;5 u` and shows "Press Ctrl-C
  again to exit". Pasted text arrives in `CSI 200~ ... CSI 201~` and lands in the input box.
- A quick double Ctrl-C exits with status 0 and leaves the terminal clean: main screen, kitty flags 0, bracketed paste, focus
  events and mouse off, title cleared, cursor visible.
- Resize 100x32 to 70x22 to 120x40 and back (also with `/help` open): the layout reflows, nothing smears. The slash menu
  (`claude-slash-menu.png`) and `/help` (`claude-help.png`, `claude-help-72x24.png`) draw with their tab bar, columns, wrapping
  and rules intact.
- Arabic typed into the input box (`claude-arabic-input.png`): `second السلام عليكم` shows the Arabic run in visual order, the
  cursor at the logical cell as accepted in Phase 4. The box rules do not mirror. (The first line reads `/hello` because the
  script typed `/` and then Esc; Esc closes the menu and keeps the slash.)

**Gaps found** (none stopped it):

1. **XTVERSION says `libghostty`**, not Harf. A program that special-cases terminals by name will treat Harf as Ghostty.
2. **`CSI 16 t` (cell size in pixels) is never answered.** Claude asks at startup and again after every resize.
3. **Kitty graphics probe** (`ESC _ G ... a=q`) and **`OSC 7501 ; ?`** are not answered (no graphics support; the second is
   unknown to me). Claude carried on within a second.
4. **Mode 2031** (color-scheme change reports) is switched on by Claude and never answered; Harf's theme is fixed anyway.

## Codex CLI 0.163.0

**Works:**

- Startup queries, all answered: cursor position (`CSI 6 n`), foreground and background color (`OSC 10;?` and `OSC 11;?`, Harf
  replies `rgb:ebeb/ebeb/ebeb` and `rgb:0f0f/0f0f/1212`), kitty keyboard query, DA1.
- Modes: 1049, mouse 1000/1002/1003/1006, `?1007l` (honored: no alternate scroll), bracketed paste, focus events, 2026, kitty
  flags 7 (`CSI > 7 u`), modifyOtherKeys reset.
- Its update dialog and its hooks dialog draw correctly (`codex-update-dialog.png`, `codex-hooks-dialog.png`: panel tint, blue
  selection bar, bold, underlined link, dim hints). A resize to 70x22 while a dialog was up redrew it. The text dump of the main
  screen shows its braille logo (U+2800 block) row by row; I did not look at a picture of that screen.
- It writes OSC 8 hyperlinks (4 per start). Harf parses them and does nothing with them (Phase 6).

**Not tested: typing, Shift+Enter, Arabic, paste, Ctrl-C, scrolling in Codex.** Every start meets gate dialogs that need a
decision which Codex saves: the update offer (option 1 runs `curl ... | sh`), "Trust this folder?" (`Trust and continue`
saves a decision) and "Hooks need review" (`Trust all and continue`). The hooks dialog arrives on its own about 28 s after
launch. I never chose an option: I pressed Esc ("skip") on the update offer, and in three runs the script's typed letters, a
paste and Shift+Enter landed in a hooks or folder dialog before I understood what was on screen (in the one run I could check,
Shift+Enter did not confirm `Trust and continue`). `config.toml`, `hooks.json` and `auth.json` keep their old dates, so I
believe nothing was saved, but I did not inspect Codex's state database, which changes on every start. Side effect: the runs
started Codex's managed app-server daemon and its updater (they run whenever Codex starts); I did not stop them.

## What this does not cover

- **Flicker and streaming.** No model turn ran, so there was no streaming reply, no repaint under load, no tool-approval
  dialog, no long output into scrollback. Both programs wrap every frame in synchronized output and Harf holds the display for
  it, but a still dump cannot show tearing. This needs eyes on the real app during a real answer.
- Mouse wheel, click and selection inside either program; focus in and out; notifications (OSC 9, 777) and clipboard (OSC 52),
  which neither emitted in these short runs.
- Key release events. Codex asks for event types (flag 2); the harness sends presses only, and I did not check that the Swift
  shell forwards releases.

## Next

1. Owner, by hand in the real app: run `claude` and `codex` for a real answer. Watch for flicker, tearing, a stuck cursor, wrong
   widths, a scrolled-off frame, selecting and copying out of the alternate screen. For Codex, choose the gate options yourself.
2. Small, safe to do next: answer `CSI 16 t`; set XTVERSION to `Harf <version>` (check whether libghostty-vt allows it).
3. Then the brief's remaining Phase 5 list: OSC 8 click, OSC 52 with a permission, OSC 9/777 notifications, kitty release events.
