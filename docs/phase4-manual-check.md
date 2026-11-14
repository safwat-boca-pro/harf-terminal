# Phase 4 manual check (Arabic rows)

Build and open: `macos/build-app.sh && open macos/.build/Harf.app`. The pictures in `docs/phase4/` (`samples.png`,
`typing-prompt.png`, `typing-bare.png`) come from `HARF_SELFTEST_PNG_DIR=<dir> macos/.build/Harf.app/Contents/MacOS/Harf --selftest`.
Only you can judge how it looks. Tell me what is off.

- [ ] The brief 4.7 strings, one `printf` each in the app (or `printf '%s\n' ...`): `مرحبا world 123`, `السلام عليكم ورحمة الله`, `مُحَمَّد`, `لا إله إلا الله`, `ls ملف.txt`, `"النتيجة: ١٢٣ (ناجح)"`, `echo "اختبار" | wc -c`, `│ مرحبا    │`. Joined letters, word order, brackets, tashkeel, lam-alef, box bars in place?
- [ ] Type `السلام عليكم` at the zsh prompt. Words stay joined; the first letter drifts right as the word grows and the cursor stays at the right of the word. Acceptable? (Decision 4 of the plan.)
- [ ] `echo "اختبار" | wc -c` typed and run: the prompt line and the output both look right.
- [ ] A pure Arabic output line with punctuation, e.g. `echo "السلام عليكم."`: the full stop on the left end (RTL base).
- [ ] The quoted sample `"النتيجة: ١٢٣ (ناجح)"`: the row starts with a quote, so it gets an LTR base (Decision 2): the opening quote is at the left and the text reads from the right. Acceptable?
- [ ] An indented Arabic line, `echo "   مرحبا"`: with an RTL base the indent ends up on the right (known quirk of Decision 2).
- [ ] `ls` in a directory with Arabic file names.
- [ ] Resize the window while Arabic is on screen: nothing smears or disappears.
- [ ] Run `claude` and type Arabic in its input box; its borders (box drawing) must not mirror.
- [ ] Option+Left / Option+Right over Arabic text: moves by the shell's logical words (Decision 5); say if it feels wrong.
- [ ] Idle: leave the window alone for a minute; CPU stays at 0.
