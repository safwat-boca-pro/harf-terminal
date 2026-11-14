# Manual check: Phase 5 leftovers, configuration, and the shell (2026-11-14)

Build and open: `macos/build-app.sh && open macos/.build/Harf.app`. Everything below has tests or a self-test behind it
(`zig build test`, `Harf --selftest`), but these are the things only a person at the keyboard can judge. Tell me what is off.

**Splits on screen:** checked by the owner from a screenshot (2026-11-14): splits and tabs draw upright. The upside-down
panes I saw earlier came from rendering the whole window offscreen with `cacheDisplay`, not from the app.

## Shell
- [x] Cmd+N opens a new window (offset from the first). *(owner, 2026-11-14)*
- [x] Cmd+T opens a tab in the current window. *(owner, 2026-11-14)*
- [x] Cmd+Shift+[ and ] switch tabs, Cmd+1 to 9 jump to one. *(owner, 2026-11-14)*
- [ ] Cmd+D splits side by side, Cmd+Shift+D splits below. The new shell starts in the directory of the one you split. Splits nest. Cmd+[ and Cmd+] move between panes; clicking a pane focuses it.
- [x] Cmd+W closes a one-pane tab. *(owner, 2026-11-14)*
- [ ] Cmd+W in a split closes only that pane (its neighbour takes the space); the last pane closes the window. `exit` in a pane closes it.
- [ ] Cmd+K empties the screen and scrollback and redraws your prompt at the top. In vim (alternate screen) it does nothing.
- [x] Ctrl+L empties only the visible screen (scroll up: the older output is still there) and redraws your prompt at the top. *(owner, 2026-11-14)*
- [ ] In vim, less or `claude` Ctrl+L is not taken by the app: the program redraws itself. `keybind = ctrl+l = unbind` hands it back to the shell.
- [ ] Cmd+F opens the find bar in the top right of the pane; typing finds and jumps to the newest match, Enter goes to older ones, Shift+Enter to newer, Esc closes. "n of m" is shown. Every match in view is tinted amber and the current one is blue (the selection, so Cmd+C copies it). It finds text in scrollback. It starts at the newest match, at the bottom.
- [ ] Open the find bar in a narrow split pane: nothing is cut off.
- [ ] Title and tab name follow the focused pane. Tab drag and "Merge All Windows" from the Window menu work.

## Shell integration (zsh; marks prompts and commands with OSC 133)
Headless run on the owner's real zsh (oh-my-zsh, `➜  ~` prompt), 2026-11-14, with and without the shim: the screen text is identical (the prompt does not change); 6 commands gave 12 start/end events, `false` ended with exit 1; Cmd+Up's action reached the oldest prompt; select-output returned only the last command's output; `$ZDOTDIR` and `$HARF_SHELL_INTEGRATION` are empty inside the shell; ` exec zsh` left no stuck running state. Not checked, because it needs eyes and a keyboard: the key presses themselves, the highlight, the dot in the tab bar, and the notification on screen.

Open a **new** window or tab so the shell starts with the shim. Your own zsh setup (prompt theme, plugins) is the thing to judge: tell me if the prompt looks different or a startup file stopped loading.
- [ ] Run a few commands, one of them long (`seq 1 200`). Cmd+Up goes to the previous prompt, again to the one before; Cmd+Down comes back. In a tab with no commands yet, nothing happens and nothing is typed at the prompt; in vim the key belongs to vim. Cmd+Shift+A right after a command that printed nothing (`true`) selects nothing.
- [ ] Cmd+Shift+A selects the output of the last command (highlighted), Cmd+C and paste elsewhere gives exactly that text, without the prompt line.
- [ ] `echo $ZDOTDIR` prints what you had before (nothing if you never set it). `print $HARF_SHELL_INTEGRATION` prints nothing.
- [ ] `sleep 5` in one tab, then look at the tab bar from another tab: its title has a dot in front until the command ends. With a single tab the dot flickers on every command, by design.
- [ ] `sleep 12`, switch to another tab or app: when it ends, a "Command finished" notification says "Done" (`false; sleep 12; false` style failures say "Failed (exit N)"). A short command makes no notification. **The OSC 9 notification did not show on screen earlier; say if this one does not either.**
- [ ] `exec zsh` does not leave the dot on the tab (the new shell has no marks until you open a new tab, which is a known limit).
- [ ] `shell_integration = off` in the config, then a new tab: no dot, Cmd+Up does nothing. bash and fish get no marks at all.

## Paste guard (a sheet before a risky paste; `paste_guard = off` turns it off)
- [ ] Copy one line of text, Cmd+V in a zsh tab: it pastes with no sheet.
- [ ] Copy two lines, Cmd+V in zsh and in Claude Code: no sheet (they use bracketed paste, so the program sees one paste).
- [ ] In a tab running `/bin/bash` (the old bash 3.2 has no bracketed paste), Cmd+V of two lines, or of a command copied with its trailing line break: a sheet says "Paste 2 lines (N bytes)?" with the reason and the first lines. Cancel (or Esc) pastes nothing; Paste (or Return) runs them as if typed. The Edit menu's Paste does the same.
- [ ] Copy more than 100 KB (`seq 1 30000 | pbcopy`), Cmd+V anywhere: a sheet says it is a very large paste.
- [ ] While the sheet is open, copy something else, then press Paste: what you first copied is pasted, not the new text.
- [ ] `paste_guard = off` in the config, then repeat the bash paste: no sheet.

## Cmd-click on paths and URLs, link coloring, and the editor picker
- [ ] `echo https://example.com/a.` prints the URL in blue and underlined, without the full stop; `echo ftp://x.org` and `echo see example.com` stay plain. A program that colors its own URLs (for example `git`, `gh`) keeps its colors.
- [ ] Cmd-click on that URL opens the browser. Cmd-click on an OSC 8 link (`printf '\e]8;;https://example.com\e\\link\e]8;;\e\\\n'`) still does too.
- [ ] Hold Cmd and move over a URL, an OSC 8 link, and a file name that exists (`echo README.md:3`): each gets a blue tint with a line under it and the pointing hand; a file that does not exist, a directory and a plain word get nothing. Let go of Cmd, or move away: it clears at once.
- [ ] In the config: `editor = vscode://file{path}:{line}:{col}`. `echo src/main.swift:12:5` then Cmd-click: VS Code opens that file at line 12, column 5 (also when VS Code is already running). **I could not run VS Code here: if the URL form needs `file//`, tell me.**
- [ ] A relative path opens relative to the pane's current directory, also after `cd` in a split.
- [ ] With no `editor` line, Cmd-click on a file name opens it in TextEdit. A file called `x.command` or an `.app` is shown as text, never launched.
- [ ] Harf menu > Choose Editor… shows the macOS app picker. Pick VS Code: `editor = vscode://file{path}:{line}:{col}` appears in `~/.config/harf/config` and takes effect at once. Pick another app (for example Sublime Text): `editor = app:/Applications/Sublime Text.app`, and the file opens in it with no line number.
- [ ] `editor = code --goto {path}:{line}:{col}` works too if `code` is installed in your shell's PATH. A file called `a; touch /tmp/pwned.txt` opens as that name and does not run anything.

## Configuration (`Cmd+,` opens `~/.config/harf/config`, creating it with every setting commented out)
- [ ] `font_size = 18` then save: the font changes at once in every window, no restart. `font_family = Monaco` works; `font_family = Helvetica` prints a warning to stderr and keeps Menlo.
- [x] Cmd+= and Cmd+- change the font size for this run. *(owner, 2026-11-14)*
- [ ] Cmd+0 puts it back.
- [ ] `theme = light` recolors everything. `theme = dark:dark, light:light` follows System Settings > Appearance live. Claude Code and Codex pick up the change (mode 2031).
- [ ] A file `~/.config/harf/themes/mine` with `background = #102030` and `theme = mine` works; editing the theme file reloads it.
- [ ] `keybind = cmd+t = new_window` remaps; `keybind = cmd+w = unbind` frees Cmd+W; `keybind = option+left = send:\e[1;3D` types that sequence. Menu shortcuts follow.
- [ ] A typo in the file prints `harf: config: line N: ...` on stderr (run the binary from a terminal to see it) and the rest still applies.
- [ ] Default theme is still dark; I did not make it follow the system unless asked.

## Phase 5 leftovers
- [ ] OSC 52: `printf '\e]52;c;%s\a' "$(printf hello | base64)"` then paste somewhere: `hello`. Run the same in a split you are not typing in (`sleep 5; ...`, then click the other pane): the clipboard must not change. `clipboard_write = deny` turns it off.
- [ ] OSC 9: `sleep 3; printf '\e]9;Build done\a'`, then click another app within 3 s: a notification appears (the first one asks for permission). With the terminal in front, nothing. `notifications = always` or `off` change that. **I could not see a notification on screen.**
- [ ] OSC 8: `printf '\e]8;;https://example.com\e\\link\e]8;;\e\\\n'` then Cmd+click `link` opens the browser. `file:` links do nothing.
- [ ] Codex: Shift+Enter, and its other keys, still behave (key releases are now sent to programs that ask for them).

## Not done, on purpose
- Reading the clipboard from a program (OSC 52 `?`) is never answered.
- No Option-as-Meta setting; the built-in Option/Cmd editing keys can be overridden with `keybind ... send:`.
- Splits and tabs are not restored after a restart (session restore is not built).
- Find is case-insensitive for ASCII only (the library's rule).
