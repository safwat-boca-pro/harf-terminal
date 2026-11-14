# Large-Paste Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cmd+V and the Edit menu's Paste ask for confirmation when the text has a line break and the program lacks bracketed paste, or when it is over 100,000 bytes; `paste_guard = off` turns it off.

**Architecture:** The decision is a Zig function (`Terminal.pasteRisk`) read through one C call (`harf_term_paste_check`); Swift's single paste entry point, `TerminalController.paste`, asks it and shows an `NSAlert` sheet through an overridable `confirmPaste` seam.

**Tech Stack:** Zig 0.17.1 (`.tools/zig`), Swift/AppKit.

**Spec:** `docs/superpowers/specs/2026-11-14-paste-guard-design.md` (approved by the owner).

## Global Constraints

- Add capability in Zig, not Swift; `include/harf.h` is hand-written and mirrors `src/capi.zig`.
- Pasted text is untrusted: the preview replaces control characters.
- Run Zig with `PATH=$PWD/.tools/zig:$PATH`; build with `macos/build-app.sh`; self-test is `macos/.build/Harf.app/Contents/MacOS/Harf --selftest`.
- Commit messages carry no attribution lines (user rule).

## Review Focus

- A one-line paste (the common case), with the guard on, never asks. Pinned in the Zig and self-tests.
- Bracketed paste on and a multi-line paste: never asks (unless over 100,000 bytes).
- A trailing newline only (`"ls\n"`) without bracketed paste asks: it would run at once.
- The clipboard changes while the sheet is open: the captured text is what is pasted. Pinned by capturing the text before asking.
- A paste of exactly 100,000 bytes does not ask; 100,001 does.

---

### Task 1: Paste guard

**Files:**
- Modify: `src/vt.zig` (after `bracketedPaste`), `src/term.zig` (next to `paste`), `src/capi.zig`, `include/harf.h`, `src/config.zig`, `macos/Sources/Harf/Settings.swift`, `macos/Sources/Harf/TerminalView.swift`, `macos/Sources/Harf/main.swift` (self-test), `docs/phase6-manual-check.md`, `ARCHITECTURE.md`
- Test: `src/vt.zig`, `src/capi.zig`, `src/config.zig`, `macos/Sources/Harf/main.swift`

**Interfaces:**
- Produces: `pub const large_paste_bytes: usize = 100_000;` and `pub const PasteRisk = struct { runs_lines: bool, large: bool };` in `src/vt.zig`; `vt.Terminal.pasteRisk(self: *Terminal, text: []const u8) PasteRisk`; `term.Session.pasteRisk(self: *Session, text: []const u8) vt.PasteRisk` (locks).
- Produces: `export fn harf_term_paste_check(t: *HarfTerm, utf8: [*]const u8, len: usize) c_int`, header `int harf_term_paste_check(HarfTerm *t, const uint8_t *utf8, size_t len);` (0 = paste without asking, bit 1 = would run lines, bit 2 = large).
- Produces: `config.Config.paste_guard: bool = true`, key `paste_guard = on|off`, `export fn harf_config_paste_guard(cfg) c_int` (1 on), `Settings.shared.pasteGuard: Bool`.
- Produces (Swift): `struct PasteSummary { var title: String; var detail: String }`; `func pasteSummary(of text: String, risk: Int32) -> PasteSummary`; `TerminalController.confirmPaste: (PasteSummary, @escaping (Bool) -> Void) -> Void` (default: an `NSAlert` sheet on `view.window`, Paste is the default button, Cancel is Esc; with no window it answers `false`).

- [ ] **Step 1: Write the failing tests.**
  - `src/vt.zig`, `test "pasteRisk: a line break risks running lines only without bracketed paste; very large always asks"`: on a fresh `Terminal`: `"one line"` is `{false,false}`; `"a\nb"`, `"a\rb"` and `"ls\n"` have `runs_lines`; after `t.write("\x1b[?2004h")` the same texts have neither flag; a text of exactly 100,000 bytes has `large == false` and one of 100,001 has `large == true`, bracketed or not.
  - `src/capi.zig`, extend `test "harf_term_key and harf_term_paste"`'s neighbour with `test "harf_term_paste_check returns the reason bits"`: a session on `/bin/sh -c "sleep 5"`: `"hi"` gives 0, `"a\nb"` gives 1, a 100,001-byte buffer gives 2, and the same buffer with a newline gives 3.
  - `src/config.zig`: in `test "settings"` add `paste_guard = off` and expect `c.paste_guard == false`; the defaults test expects `true`; add `"paste_guard = "` to the template's key list in `test "every example line of the template is valid once uncommented"`.
  - `macos/Sources/Harf/main.swift`, new section after 3 (paste): a controller on the same `echo` script the paste section uses, `confirmPaste` replaced by a closure that records the summary and answers a variable. Cases: `paste("x y")` never calls it; with bracketed paste off, `paste("a\nb")` calls it once, answering `false` sends nothing to the child, answering `true` delivers the text; with `Settings.shared.pasteGuard` false it never asks; `pasteSummary(of: "line1\nline2\u{1b}[31m", risk: 1)` has a title naming 2 lines and a detail without the ESC character.
- [ ] **Step 2: Run them, expect FAIL.** `PATH=$PWD/.tools/zig:$PATH zig build test -Dtest-filter="pasteRisk"` fails to compile (no `pasteRisk`); likewise for `paste_check` and the config tests; `macos/build-app.sh` fails on `confirmPaste`/`pasteSummary`.
- [ ] **Step 3: Implement** `Terminal.pasteRisk` (LF or CR present and not `bracketedPaste()`; `text.len > large_paste_bytes`), `Session.pasteRisk`, the C call and header, the config key (parse `on`/`off` with a warning otherwise, template comment, `harf_config_paste_guard`), `Settings.pasteGuard`, and in `TerminalController.paste`: copy the text to bytes first, return early on empty, ask `harf_term_paste_check` only if `Settings.shared.pasteGuard`, send immediately when 0, otherwise call `confirmPaste` and send the captured bytes if answered true. `pasteSummary`: title `"Paste N lines (X KB)?"` (or just the size for one line), detail = the reason sentence(s) plus up to five preview lines of at most 80 characters, control characters other than tab shown as `·`, `…` when cut.
- [ ] **Step 4: Run the filtered tests, the full `zig build test` (258 passed, 4 skipped before, plus the new ones), `macos/build-app.sh` and the self-test, expect PASS.**
- [ ] **Step 5: Docs.** Add a "Paste guard" section to `docs/phase6-manual-check.md` (Cmd+V of one line: nothing; a multi-line paste at a plain `bash` 3.2 prompt, `/bin/bash`: the sheet, Cancel pastes nothing, Paste runs the lines; the same multi-line text in zsh or Claude Code: no sheet; a paste over 100 KB: the sheet; `paste_guard = off`: never) and one decision-log row in `ARCHITECTURE.md` (rule, why bracketed paste is exempt, the fixed threshold).
- [ ] **Step 6: Commit** `Paste guard: confirm before a paste that would run lines (no bracketed paste) or is over 100 KB; paste_guard = on|off`.

---

## Not in this plan

- A setting for the threshold; a guard for drag-and-drop (there is none), OSC 52 or `send:`.
- A "remember my answer" checkbox.
