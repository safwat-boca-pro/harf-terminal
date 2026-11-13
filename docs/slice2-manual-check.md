# Slice 2: hands-on check

Build and open the app: `macos/build-app.sh && open macos/.build/Harf.app`. The automated checks
(`zig build test`, `Harf --selftest`) cannot judge feel, so run these yourself and tell me what is off.

- [ ] A window titled "Harf" opens with your zsh prompt in it, at your home directory.
- [ ] Type `ls` and Return: the listing appears. Backspace erases one character at a time.
- [ ] `echo مرحبا` prints the word. Letters are separate and unjoined (expected until Phase 4), and nothing overlaps.
- [ ] Switch to an Arabic keyboard layout and type: letters arrive in the shell. Backspace erases a whole letter.
- [ ] Up and down arrows walk through history; left and right move the cursor; Ctrl+A / Ctrl+E jump to line start and end.
- [ ] Copy a few lines from another app and press Cmd+V: they paste (a multi-line paste runs line by line in zsh).
- [ ] `sleep 30`, then Ctrl+C: the prompt comes back.
- [ ] Drag the window corner: the prompt and text stay put, `stty size` reports the new size, no crash when it gets tiny.
- [ ] `printf '\033]0;hello\007'` changes the window title; `printf '\a'` makes the alert sound.
- [ ] `exit` closes the window and quits the app.
- [ ] Launch with a broken shell: `SHELL=/usr/bin/false macos/.build/Harf.app/Contents/MacOS/Harf`: the window stays and its title says `exited (1)`.
- [ ] Idle: leave it for a minute. Activity Monitor shows 0.0% CPU for Harf.
- [ ] Cmd+Q quits; Cmd+W closes the window.
