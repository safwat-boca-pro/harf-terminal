# Cmd-click on `path:line:col` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cmd-click on `src/a.zig:12:5` (absolute, `~/`, or relative to the pane's directory) opens that file at that line in the editor named by `editor = ...` (VS Code through `vscode://file/{path}:{line}:{col}`), or in the default text editor when none is set.

**Architecture:** The core finds the path token and its line/column under a click (`Terminal.pathAt`, one C call); Swift resolves it, checks the file exists, and launches it through a pure `editorLaunch` function (URL template, command template run without a shell, or the default plain-text editor).

**Tech Stack:** Zig 0.17.1 (`.tools/zig`), Swift/AppKit.

**Spec:** `docs/superpowers/specs/2026-11-14-path-click-design.md`.

## Global Constraints

- Add capability in Zig, not Swift; `include/harf.h` mirrors `src/capi.zig`.
- A file name from terminal output is untrusted: it is never passed through a shell command line, and the default open never launches an app or script.
- Run Zig with `PATH=$PWD/.tools/zig:$PATH`; build with `macos/build-app.sh`; self-test is `macos/.build/Harf.app/Contents/MacOS/Harf --selftest`.
- Commit with `git add -u` plus named new files only (an unrelated untracked `README.md` sits in the working tree and is not ours). Commit messages carry no attribution lines (user rule).

## Review Focus

- A filename with spaces, `;`, `$(...)`, quotes or a leading `-` in command mode reaches the editor as ONE argument (never split, never run by a shell).
- A path naming an `.app` or a `.command` file never launches under the default (no `editor`): it opens as text.
- A directory, a missing file, and a word that is not a file do nothing.
- Wide characters (CJK) and Arabic text before the path do not shift the column the click maps to.
- A token longer than the buffer is not opened (never a cut-off path); a click on blank does nothing.
- `{line}` and `{col}` are 1 when the text has none; line 0 is treated as no line.

---

### Task 1: Find the path under a click (core and C ABI)

**Files:**
- Modify: `src/vt.zig` (next to `hyperlinkAt`), `src/capi.zig` (next to `harf_term_hyperlink_at`), `include/harf.h`
- Test: `src/vt.zig`

**Interfaces:**
- Produces: `pub const PathRef = struct { len: usize, line: u32, col: u32 };` and `vt.Terminal.pathAt(self: *Terminal, col: u16, row: u16, out: []u8) ?PathRef` (the path text is copied into `out[0..len]`; `line` and `col` are 0 when the text has none).
- Produces: `export fn harf_term_path_at(t: *HarfTerm, p: *draw.Painter, x_px: f64, y_px: f64, out: [*]u8, cap: usize, line: *u32, col: *u32) usize`, header `size_t harf_term_path_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint8_t *out, size_t cap, uint32_t *line, uint32_t *col);` (length, 0 = none; same pixel convention as `harf_term_hyperlink_at`).

- [ ] **Step 1: Write the failing test** `test "pathAt finds the path token under a cell and its line and column"` in `src/vt.zig` with a table. Write the row, then click a column inside the token: `"see src/main.zig:12:5: error"` on a column in `src` gives path `src/main.zig`, line 12, col 5; `"open foo.txt, then"` gives `foo.txt`, 0, 0; `"(~/notes.md)"` gives `~/notes.md`; `"file.zig:7"` gives line 7, col 0; a click on a space gives null; `"漢字 a/b.c:9"` (each CJK character takes two columns) clicked on the column of `a` gives `a/b.c`, line 9; `"مرحبا src/x.zig:3"` clicked on `x` gives `src/x.zig`, line 3; a 3-byte `out` buffer on `src/main.zig:1` gives null.
- [ ] **Step 2: Run it, expect FAIL.** `PATH=$PWD/.tools/zig:$PATH zig build test -Dtest-filter="pathAt"` fails to compile (no `pathAt`).
- [ ] **Step 3: Implement** `pathAt` over the row's cells (a column is a cell; a wide character covers two columns, a spacer cell continues it): find the run of non-space cells containing the clicked cell, with the delimiter set from the spec as run boundaries; encode the run as UTF-8; strip trailing `.` `:` `!` `?` and `)` that were not boundaries; read a trailing `:digits` or `:digits:digits` (optionally followed by `:`) as line and col; fail if what is left is empty or does not fit `out`. Then the C export (convert pixels with `p.cellAt` like `harf_term_hyperlink_at`) and the header.
- [ ] **Step 4: Run the filtered test and the full `zig build test`, expect PASS.**
- [ ] **Step 5: Commit** `pathAt: find the path token, line and column under a click`.

### Task 2: Open it (config, Swift, docs)

**Files:**
- Modify: `src/config.zig` (key `editor`), `src/capi.zig` + `include/harf.h` (`harf_config_editor`), `macos/Sources/Harf/Settings.swift`, `macos/Sources/Harf/TerminalView.swift`, `macos/Sources/Harf/main.swift` (self-test), `docs/phase6-manual-check.md`, `ARCHITECTURE.md`
- Test: `src/config.zig`, `macos/Sources/Harf/main.swift`

**Interfaces:**
- Consumes: Task 1's `harf_term_path_at`.
- Produces: `config.Config.editor: [:0]const u8 = ""` (up to 256 bytes; longer is a warning), key `editor = <text>`, `export fn harf_config_editor(cfg: *config.Config) [*:0]const u8`, `Settings.shared.editor: String`.
- Produces (Swift): `struct PathTarget { var url: URL; var line: Int; var col: Int }`; `enum EditorLaunch: Equatable { case textEditor; case url(URL); case command([String]) }`; `func editorLaunch(template: String, path: String, line: Int, col: Int) -> EditorLaunch` (pure; `{line}`/`{col}` become 1 when given 0); `TerminalController.pathTarget(at: NSPoint) -> PathTarget?`; `TerminalController.openPath: (PathTarget) -> Void` (overridable; default launches per `Settings.shared.editor`).

- [ ] **Step 1: Write the failing tests.**
  - `src/config.zig`: `editor = vscode://file/{path}:{line}:{col}` parses (`c.editor` equals it), the default is empty, a 300-byte value is a warning, and `"editor = "` is added to the template key list in `test "every example line of the template is valid once uncommented"`.
  - `macos/Sources/Harf/main.swift`, new section after the paste-guard section (3b): (a) `editorLaunch(template: "vscode://file/{path}:{line}:{col}", path: "/tmp/my dir/a b.swift", line: 12, col: 5)` equals `.url` of `vscode://file//tmp/my%20dir/a%20b.swift:12:5`; (b) `editorLaunch(template: "code --goto {path}:{line}:{col}", path: "/tmp/x; rm -rf ~ $(id) 'q'.txt", line: 0, col: 0)` equals `.command(["code", "--goto", "/tmp/x; rm -rf ~ $(id) 'q'.txt:1:1"])` (one argument, no shell); (c) an empty template gives `.textEditor`; (d) `pathTarget(at:)`: in a temp directory holding `b.txt`, a controller started with that `cwd` printing `see b.txt:4:2 ok` gives a target with url ending `/b.txt`, line 4, col 2, and the same with an absolute path; `missing.txt:1` and a directory give nil; a click on a blank cell gives nil; (e) a Command-click (`mouseDown` with the command flag) on that cell calls the overridden `openPath` once with that target, and a plain click does not.
- [ ] **Step 2: Run them, expect FAIL** (compile errors for `editor`, `editorLaunch`, `pathTarget`, `openPath`).
- [ ] **Step 3: Implement** the config key, `harf_config_editor`, `Settings.editor`; `editorLaunch` (a template matching `^[A-Za-z][A-Za-z0-9+.-]*://` is a URL template with values percent-encoded, `{path}` keeping `/`; otherwise split the template on spaces and substitute into each word; empty is `.textEditor`); `pathTarget(at:)` (call `harf_term_path_at`, expand `~`, resolve a relative path against `currentDirectory()` or the home directory, require a regular file via `FileManager`); the default `openPath`: `.url` goes to `NSWorkspace.shared.open`, `.command` runs `$SHELL -l -c 'exec "$@"' harf <argv...>` with `Process` and null stdio (login shell for the PATH; failure writes `harf: editor: ...` to stderr), `.textEditor` opens the file with the app from `NSWorkspace.shared.urlForApplication(toOpen: .plainText)`, never the file's own handler; and in `TerminalView.mouseDown` after the OSC 8 check: `else if command, let target = controller?.pathTarget(at: p) { controller?.openPath(target); return }`.
- [ ] **Step 4: Run the filtered tests, the full `zig build test`, `macos/build-app.sh` and the self-test, expect PASS.**
- [ ] **Step 5: Docs.** `docs/phase6-manual-check.md` gets a "Cmd-click on paths" section: with `editor = vscode://file/{path}:{line}:{col}` in the config, `ls src` then `echo src/main.zig:12:5` and Cmd-click opens VS Code at that line and column; a relative path opens relative to the pane's directory (also after `cd`); a nonexistent path, a directory, and a plain word do nothing; with no `editor` set the file opens in TextEdit; Cmd-click on an OSC 8 link still opens the browser. Add the VS Code (URL and `code --goto`) and Cursor/Zed lines to the config template comments, and one decision-log row in `ARCHITECTURE.md`.
- [ ] **Step 6: Commit** `Cmd-click on path:line:col opens it in the editor (editor = URL or command template; default text editor)`.

---

## Not in this plan

- Hover underline or cursor; paths wrapped over two rows; `path(line,col)` and `path line N` forms; directories; a per-project editor.
