# Slice 4 manual check (conformance and numbers)

Owner pass 2026-11-14: every ticked box passed; no problems reported. Boxes left open were not covered by that pass.

Build and open: `macos/build-app.sh && open macos/.build/Harf.app`. Only you can judge feel and looks; tell me what is off.

**Programs, a few minutes each in the real app** (typing, resizing the window, the mouse, selecting and copying, Arabic text where the program allows)
- [x] `vim` with a syntax-highlighted file: colors, line numbers, `:set mouse=a` with the wheel and clicks, resize while editing, quit and the shell comes back intact.
- [x] `tmux`: split panes (Ctrl-B then `%` and `"`), the borders and the status bar, move between panes, detach and reattach (`tmux ls`, `tmux attach`). Try `set -g mouse on`.
- [x] `htop` (or `top`): colored meters, the function-key bar, sorting, killing nothing, `q` to quit.
- [x] `less` on a long file: paging, search with `/`, `q`.
- [x] `fzf` (for example `ls | fzf`, or Ctrl-R if you have fzf's shell integration): filter, arrows, Enter, Escape.
- [x] After each of them, scroll back through your shell's history: the program's screens must not be in it.

**vttest**
- [ ] Open `docs/conformance/vttest.md` and fill in the Owner column; run `vttest` by hand for the 7 "needs a human" screens (menu 3.4 to 3.7, 3.13, 11.1.7) and any of the 151 unwalked deeper paths you care about. Decide what to do about finding F1 (132-column mode).
- [ ] Re-create all the pictures if you want to look at them: `macos/.build/Harf.app/Contents/MacOS/Harf --conformance /tmp/vt` (about 7 minutes, 8 MB).

**Numbers**
- [ ] `bench/footprint.sh 15 settled` (and `scrollback`, `flood`): about 25 to 26 MB each at 700x420 pt.
- [ ] `bench/idle.sh macos/.build/Harf.app 60`: idle CPU about 0.01 percent.
- [ ] `bench/startup.sh 10`: about 120 ms; decide the startup budget question in `docs/phase3-done.md`.
- [x] The window now uses the sRGB color space (to save about 5 MB): look at the theme and the ANSI colors in `ls --color` and vim; tell me if they look wrong on your display.

**Closed decisions (only a person can judge these)**
- [x] Selection: double-click a word in the shell, hold the button and drag across two more words: whole words are selected, in both directions. Triple-click and drag: whole lines.
- [x] Wheel in `less` or `man` still scrolls. In a program that resets mode 1007 (`printf '\e[?1049h\e[?1007l'; sleep 30`) the wheel does nothing.
- [x] A program that never ends a synchronized update (`printf '\e[?2026h'; echo stuck; sleep 30`) shows `stuck` after about a second.
- [x] Run `vttest`, menu 1, the 132-column screens: the window widens to fit 132 columns and returns to 80 when vttest switches back. (`printf '\e[?40h\e[?3h'` does it by hand.)

**Dirty rows (P3)** (the one thing no test here can see: that AppKit keeps the untouched rows between partial redraws)
- [x] Use the app for a few minutes: type, run `ls --color`, `vim`, scroll the wheel through output, select with the mouse, switch windows and back, switch the cursor with `printf '\e[5 q'`. Nothing should ever look stale, torn or half-drawn (a row of old text, a ghost cursor, a missing selection edge).
- [ ] If something does, start the app with `HARF_FULL_REDRAW=1` and see whether it goes away; tell me what you did.
