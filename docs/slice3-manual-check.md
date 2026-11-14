# Slice 3 manual check (colors, scrollback, mouse, focus, copy)

Build and open: `macos/build-app.sh && open macos/.build/Harf.app`. Pictures from the self-test are in `docs/slice3/`
(`HARF_SELFTEST_PNG_DIR=<dir> macos/.build/Harf.app/Contents/MacOS/Harf --selftest`). Only you can judge feel and looks.

**Colors and styles**
- [ ] `ls -G` or `ls --color` in a directory with Arabic and Latin names: colors per entry, Arabic words keep their colors.
- [ ] A color test: `for i in {0..255}; do printf '\e[48;5;%dm  ' $i; done; echo`, then bold/italic/underline/strike/inverse/faint lines (`printf '\e[1mbold\e[0m \e[3mitalic\e[0m \e[4mu\e[0m \e[9mstrike\e[0m \e[2mfaint\e[0m \e[7minverse\e[0m\n'`).
- [ ] A bold Latin word on a row that also has Arabic stays regular weight (known, Decision 3).
- [ ] `vim` with a colorscheme, and `htop` or `top`: colors and the highlighted bars look right.

**Scrollback and the alternate screen**
- [ ] `seq 1 500`, then scroll back with the trackpad and a mouse wheel: smooth, no jumps, stops at the top and bottom; new output does not drag the view.
- [ ] Scrolled up, type a letter: the view returns to the bottom and the letter shows.
- [ ] `less /etc/services` and `man ls`: the wheel scrolls the pager (arrow keys), not the window.
- [ ] `vim` with `:set mouse=a`: wheel scrolls, a click moves the cursor. A two-finger trackpad drag of about 10 rows scrolls about 10 lines, not about 30.

**Mouse**
- [ ] `tmux` with `set -g mouse on`: click a pane, drag a pane border, wheel. Shift-drag selects text instead.
- [ ] `printf '\e[?1000h\e[?1006h'; cat -v` then click: `^[[<0;COL;ROWM` and `m`; `printf '\e[?1000l\e[?1006l'` to stop.

**Focus**
- [ ] Click another window: the cursor becomes a hollow block; click back: solid.
- [ ] `printf '\e[?1004h'; cat -v`, then click away and back: `^[[O` then `^[[I`.

**Selection and copy**
- [ ] Drag over Latin text, Cmd+C, paste into another app: exact text. Double-click selects a word, triple-click a line.
- [ ] Drag over Arabic text in reading order (right to left), Cmd+C, paste: the logical text. A left-to-right drag over an Arabic row selects the logical range between the two ends and may select very little (visual selection is Phase 7): tell me if that is too surprising.
- [ ] Click once without dragging: the selection goes away. Typing a character, Enter, an arrow key or a paste also clears it; Shift alone and Cmd+C do not. Cmd+C with nothing selected does nothing.
- [ ] Select text, then run `clear` or scroll: the highlight follows the content when it scrolls; a program that rewrites the cells in place keeps the highlight until you click.
- [ ] Resize the window while scrolled up and while text is selected.
- [ ] Idle for a minute with the window focused: CPU stays at 0.
