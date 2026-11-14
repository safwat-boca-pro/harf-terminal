# Large-paste guard (design, approved by the owner 2026-11-14)

Spec source: `PROJECT_BRIEF.md` §6, "Large-paste guard (confirm before pasting very large or multi-line content)". A small change: this is the short design.

## Intent and why

A paste can do damage before the user has looked at it. In a program that has not asked for bracketed paste (macOS `/bin/bash` 3.2, `cat`, a shell on an old host over ssh) every pasted line runs the moment it arrives, so a copied command with a trailing newline, or a copied script, executes unseen. A very large paste can also flood the program. The guard makes the user confirm those cases and nothing else.

## Goals

- Ask before a paste that (a) contains a line break while the program has not enabled bracketed paste, or (b) is larger than 100,000 bytes (any mode).
- One choke point: both Cmd+V and the Edit menu's Paste go through `TerminalController.paste`.
- The question names what is coming (line count, size, the reason) and shows a short, sanitized preview.
- Testable without a person: a seam lets the self-test answer the sheet.

## Non-goals and anti-goals

- No confirmation for a multi-line paste into a program with bracketed paste (zsh, vim, Claude Code, Codex): it sees one paste, and asking would nag on every prompt. This is the one deliberate narrowing of the brief's literal wording; changing it is a one-line change to the rule.
- No setting for the 100,000-byte threshold. No guard for OSC 52 or `send:` bindings (they are not pastes).
- Anti-goal: a dialog that appears for ordinary pastes. If it appears for a one-line paste, the guard has failed.

## Constraints

- The decision is Zig (the brief: add capability in Zig, not Swift); Swift only shows the sheet. `include/harf.h` is hand-written and mirrors `src/capi.zig`.
- Pasted text is untrusted: the preview replaces control characters before showing them.
- The text is captured when Cmd+V is pressed; a clipboard change while the sheet is open does not change what is pasted.

## Approaches considered

1. **Confirm every multi-line paste** (the brief's literal words). Simple, but it would ask on every multi-line prompt pasted into Claude Code and Codex, the main use of this terminal. Rejected.
2. **Risk-based: line break without bracketed paste, or very large** (chosen, the owner approved it). Asks exactly when the program cannot tell a paste from typing, or the paste is big.
3. **Large only.** Ignores the real danger (lines running on arrival). Rejected.

## Design

- `vt.Terminal.pasteRisk(text) PasteRisk` with `runs_lines` (contains LF or CR and `!bracketedPaste()`) and `large` (`text.len > 100_000`). `Session.pasteRisk`. C `int harf_term_paste_check(HarfTerm *t, const uint8_t *utf8, size_t len)`: bit 1 = runs lines, bit 2 = large, 0 = paste without asking.
- `paste_guard = on|off` in the config (default on), read like `clipboard_write`.
- Swift: `TerminalController.paste` asks `harf_term_paste_check` when the guard is on; a non-zero answer goes to `confirmPaste(summary, done)`, whose default shows an `NSAlert` sheet on the window ("Paste N lines (X KB)?", the reason, up to five preview lines, buttons Paste (default) and Cancel (Esc)); with no window it cancels. `pasteSummary(of:risk:)` builds the text and is tested alone.

## Left to the builder

Exact wording of the sheet text (keep it short, plain), the preview truncation widths (about 80 characters a line), where the checklist lines go in `docs/phase6-manual-check.md`.
