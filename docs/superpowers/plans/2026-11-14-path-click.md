# Cmd-click on `path:line:col` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cmd-click on `src/a.zig:12:5` (absolute, `~/`, or relative to the pane's directory) opens that file at that line in the editor named by `editor = ...` (VS Code through `vscode://file{path}:{line}:{col}`), or in the default text editor when none is set; Cmd-click on a plain `https://...` opens the browser; "Choose Editor…" picks the app from the system and writes the config line.

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
- A token longer than the buffer is not opened (never a cut-off path or URL); a click on blank does nothing.
- URLs: trailing `.` or `,` is not part of the URL; `Foo_(bar)` keeps its balanced parenthesis while `(see https://x.com)` loses the closing one; `[docs](https://x.com/y)` opens only when the URL part is clicked; `ftp://`, `file://` and `javascript:` text never opens.
- The picker never writes a line that breaks the config: an existing `editor =` line is replaced in place, a comment mentioning `editor` is left alone, a template containing a newline is refused.
- `{line}` and `{col}` are 1 when the text has none; line 0 is treated as no line.

---

### Task 1: Find the path or URL under a click (core and C ABI)

**Files:**
- Modify: `src/vt.zig` (next to `hyperlinkAt`), `src/capi.zig` (next to `harf_term_hyperlink_at`), `include/harf.h`
- Test: `src/vt.zig`

**Interfaces:**
- Produces: `pub const PathRef = struct { len: usize, line: u32, col: u32 };` and `vt.Terminal.pathAt(self: *Terminal, col: u16, row: u16, out: []u8) ?PathRef` (the path text is copied into `out[0..len]`; `line` and `col` are 0 when the text has none).
- Produces: `vt.Terminal.urlAt(self: *Terminal, col: u16, row: u16, out: []u8) ?usize` (the URL text is copied into `out[0..len]`) and `export fn harf_term_url_at(t: *HarfTerm, p: *draw.Painter, x_px: f64, y_px: f64, out: [*]u8, cap: usize) usize`, header `size_t harf_term_url_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint8_t *out, size_t cap);`.
- Produces: `export fn harf_term_path_at(t: *HarfTerm, p: *draw.Painter, x_px: f64, y_px: f64, out: [*]u8, cap: usize, line: *u32, col: *u32) usize`, header `size_t harf_term_path_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint8_t *out, size_t cap, uint32_t *line, uint32_t *col);` (length, 0 = none; same pixel convention as `harf_term_hyperlink_at`).

- [ ] **Step 1: Write the failing test** `test "pathAt finds the path token under a cell and its line and column"` in `src/vt.zig` with a table. Write the row, then click a column inside the token: `"see src/main.zig:12:5: error"` on a column in `src` gives path `src/main.zig`, line 12, col 5; `"open foo.txt, then"` gives `foo.txt`, 0, 0; `"(~/notes.md)"` gives `~/notes.md`; `"file.zig:7"` gives line 7, col 0; a click on a space gives null; `"漢字 a/b.c:9"` (each CJK character takes two columns) clicked on the column of `a` gives `a/b.c`, line 9; `"مرحبا src/x.zig:3"` clicked on `x` gives `src/x.zig`, line 3; a 3-byte `out` buffer on `src/main.zig:1` gives null.
- [ ] **Step 1b: Write the failing test** `test "urlAt finds a plain http or https URL under a cell"`: `"visit https://example.com/a?b=1&c=2. Then"` clicked on `example` gives `https://example.com/a?b=1&c=2`; `"(https://en.wikipedia.org/wiki/Foo_(bar))"` gives `https://en.wikipedia.org/wiki/Foo_(bar)`; `"(see https://x.com)"` clicked on the URL gives `https://x.com`; `"[docs](https://x.com/y)"` clicked on `docs` gives null and clicked on `x.com` gives `https://x.com/y`; `"HTTP://EXAMPLE.COM/x"` is accepted; `"see ftp://x.org/a"`, `"https://"` alone, `"file:///etc/passwd"`, a click on a space, and a 4-byte `out` give null.
- [ ] **Step 2: Run them, expect FAIL.** `PATH=$PWD/.tools/zig:$PATH zig build test -Dtest-filter="pathAt"` and `-Dtest-filter="urlAt"` fail to compile (no `pathAt`, no `urlAt`).
- [ ] **Step 3: Implement** `pathAt` over the row's cells (a column is a cell; a wide character covers two columns, a spacer cell continues it): find the run of non-space cells containing the clicked cell, with the delimiter set from the spec as run boundaries; encode the run as UTF-8; strip trailing `.` `:` `!` `?` and `)` that were not boundaries; read a trailing `:digits` or `:digits:digits` (optionally followed by `:`) as line and col; fail if what is left is empty or does not fit `out`. Then the C export (convert pixels with `p.cellAt` like `harf_term_hyperlink_at`) and the header.
- [ ] **Step 4: Run the filtered test and the full `zig build test`, expect PASS.**
- [ ] **Step 5: Commit** `pathAt and urlAt: find the path or plain URL under a click`.

### Task 2: Open it (config, Swift)

**Files:**
- Modify: `src/config.zig` (key `editor`), `src/capi.zig` + `include/harf.h` (`harf_config_editor`), `macos/Sources/Harf/Settings.swift`, `macos/Sources/Harf/TerminalView.swift`, `macos/Sources/Harf/main.swift` (self-test), `docs/phase6-manual-check.md`, `ARCHITECTURE.md`
- Test: `src/config.zig`, `macos/Sources/Harf/main.swift`

**Interfaces:**
- Consumes: Task 1's `harf_term_path_at` and `harf_term_url_at`.
- Produces: `config.Config.editor: [:0]const u8 = ""` (up to 256 bytes; longer is a warning), key `editor = <text>`, `export fn harf_config_editor(cfg: *config.Config) [*:0]const u8`, `Settings.shared.editor: String`.
- Produces (Swift): `struct PathTarget { var url: URL; var line: Int; var col: Int }`; `enum EditorLaunch: Equatable { case textEditor; case app(URL); case url(URL); case command([String]) }` (`editor = app:/Applications/Name.app` is `.app`); `TerminalController.urlTarget(at: NSPoint) -> URL?` (http or https only); `TerminalController.openURL: (URL) -> Void` (overridable; default `NSWorkspace.shared.open`); `func editorLaunch(template: String, path: String, line: Int, col: Int) -> EditorLaunch` (pure; `{line}`/`{col}` become 1 when given 0); `TerminalController.pathTarget(at: NSPoint) -> PathTarget?`; `TerminalController.openPath: (PathTarget) -> Void` (overridable; default launches per `Settings.shared.editor`).

- [ ] **Step 1: Write the failing tests.**
  - `src/config.zig`: `editor = vscode://file{path}:{line}:{col}` parses (`c.editor` equals it), the default is empty, a 300-byte value is a warning, and `"editor = "` is added to the template key list in `test "every example line of the template is valid once uncommented"`.
  - `macos/Sources/Harf/main.swift`, new section after the paste-guard section (3b): (a) `editorLaunch(template: "vscode://file{path}:{line}:{col}", path: "/tmp/my dir/a b.swift", line: 12, col: 5)` equals `.url` of `vscode://file/tmp/my%20dir/a%20b.swift:12:5`; (b) `editorLaunch(template: "code --goto {path}:{line}:{col}", path: "/tmp/x; rm -rf ~ $(id) 'q'.txt", line: 0, col: 0)` equals `.command(["code", "--goto", "/tmp/x; rm -rf ~ $(id) 'q'.txt:1:1"])` (one argument, no shell); (c) an empty template gives `.textEditor`; (d) `pathTarget(at:)`: in a temp directory holding `b.txt`, a controller started with that `cwd` printing `see b.txt:4:2 ok` gives a target with url ending `/b.txt`, line 4, col 2, and the same with an absolute path; `missing.txt:1` and a directory give nil; a click on a blank cell gives nil; (e) a Command-click (`mouseDown` with the command flag) on that cell calls the overridden `openPath` once with that target, and a plain click does not; (f) `editorLaunch(template: "app:/Applications/Sublime Text.app", ...)` is `.app(URL(fileURLWithPath: "/Applications/Sublime Text.app"))`; (g) plain text `see https://example.com/a. ok` Command-clicked on the URL calls the overridden `openURL` with `https://example.com/a` and not `openPath`; `ftp://x.org/f` does neither; an OSC 8 link still wins over a plain URL under the same cell.
- [ ] **Step 2: Run them, expect FAIL** (compile errors for `editor`, `editorLaunch`, `pathTarget`, `openPath`).
- [ ] **Step 3: Implement** the config key, `harf_config_editor`, `Settings.editor`; `editorLaunch` (a template matching `^[A-Za-z][A-Za-z0-9+.-]*://` is a URL template with values percent-encoded, `{path}` keeping `/`; otherwise split the template on spaces and substitute into each word; empty is `.textEditor`); `pathTarget(at:)` (call `harf_term_path_at`, expand `~`, resolve a relative path against `currentDirectory()` or the home directory, require a regular file via `FileManager`); the default `openPath`: `.url` goes to `NSWorkspace.shared.open`, `.app(url)` opens the file with `NSWorkspace.shared.open([file], withApplicationAt: url, configuration:)`, `.command` runs `$SHELL -l -c 'exec "$@"' harf <argv...>` with `Process` and null stdio (login shell for the PATH; failure writes `harf: editor: ...` to stderr), `.textEditor` opens the file with the app from `NSWorkspace.shared.urlForApplication(toOpen: .plainText)`, never the file's own handler; and in `TerminalView.mouseDown` after the OSC 8 check: `else if command, let url = controller?.urlTarget(at: p) { controller?.openURL(url); return } else if command, let target = controller?.pathTarget(at: p) { controller?.openPath(target); return }`.
- [ ] **Step 4: Run the filtered tests, the full `zig build test`, `macos/build-app.sh` and the self-test, expect PASS.**
- [ ] **Step 5: Commit** `Cmd-click on path:line:col and on plain http(s) URLs (editor = URL, command or app template; default text editor)`.

### Task 3: Choose the editor from the system (picker, docs)

**Files:**
- Modify: `macos/Sources/Harf/Settings.swift`, `macos/Sources/Harf/App.swift` (menu item and its action), `macos/Sources/Harf/main.swift` (self-test), `docs/phase6-manual-check.md`, `ARCHITECTURE.md`, `src/config.zig` (template comment)
- Test: `macos/Sources/Harf/main.swift`

**Interfaces:**
- Consumes: Task 2's `editor` key and `Settings.shared.editor`.
- Produces: `func editorTemplate(forBundleID id: String?, appPath: String) -> String` (the table in the spec; anything else is `app:` plus the path); `func configText(_ text: String, settingEditor template: String) -> String` (replaces the first uncommented `editor =` line in place or appends one, leaving comments alone; one trailing newline); `Settings.shared.setEditor(_ template: String)` (refuses a template with a newline; writes through `ensureConfigFile()`'s path; the watcher reloads); menu item "Choose Editor…" in the Harf menu (action name `choose_editor`, no shortcut), which shows an `NSOpenPanel` (`.app` only, directory `/Applications`) and calls `setEditor`.

- [ ] **Step 1: Write the failing tests** in `main.swift`: `editorTemplate(forBundleID: "com.microsoft.VSCode", appPath: "/Applications/Visual Studio Code.app")` is `vscode://file{path}:{line}:{col}`; Cursor's bundle id gives `cursor://file{path}:{line}:{col}`; an unknown id (and nil) gives `app:/Applications/Other.app`. `configText("font_size = 15\n# editor = old\neditor = x\n", settingEditor: "y")` is `"font_size = 15\n# editor = old\neditor = y\n"`; with no editor line the line is appended after the existing text with exactly one newline; empty text gives `"editor = y\n"`. `Settings.shared.setEditor("a\nb")` changes nothing. End to end: load a temp config directory, `setEditor("vscode://file{path}:{line}:{col}")`, then `Settings.shared.load(directory:)` again reads `Settings.shared.editor` back as that text.
- [ ] **Step 2: Run, expect FAIL** (compile errors).
- [ ] **Step 3: Implement** the three functions, the menu item (add `("Choose Editor…", "choose_editor")` to the Harf menu in `menuLayout`; `AppDelegate.perform` handles `choose_editor` by showing the panel) and the config-template comment lines (VS Code URL and `code --goto` forms, Cursor, and the `app:` form).
- [ ] **Step 4: Run the full `zig build test`, `macos/build-app.sh` and the self-test, expect PASS.**
- [ ] **Step 5: Docs.** `docs/phase6-manual-check.md` gets a "Cmd-click on paths and URLs" section: Cmd-click on a plain `https://example.com` printed by `echo` opens the browser (a trailing full stop is not part of it; `ftp://` does nothing); the Harf menu's "Choose Editor…" shows the app picker, picking VS Code writes `editor = vscode://file{path}:{line}:{col}` into the config and picking another app writes `editor = app:/Applications/Name.app` (opens without a line number); with `editor = vscode://file{path}:{line}:{col}` in the config, `ls src` then `echo src/main.zig:12:5` and Cmd-click opens VS Code at that line and column; a relative path opens relative to the pane's directory (also after `cd`); a nonexistent path, a directory, and a plain word do nothing; with no `editor` set the file opens in TextEdit; Cmd-click on an OSC 8 link still opens the browser. Add one decision-log row in `ARCHITECTURE.md`.
- [ ] **Step 6: Commit** `Choose Editor... picks the app from the system and writes the editor line; checklist and decision log`.

### Task 4: Plain URLs are always colored (painter)

**Files:**
- Modify: `src/vt.zig` (`urlEndFrom` shared with `urlAt`; `markUrls`), `src/draw.zig` (`gather` calls it)
- Test: `src/vt.zig`, `src/draw.zig`

**Interfaces:**
- Produces: `vt.markUrls(cells: []Cell, color: Rgb) void`: for each plain `http://` or `https://` URL in the row (found as `urlAt` finds one: scheme start, run to a space or quote or angle bracket, trailing punctuation and unbalanced closing brackets removed), sets `style.fg = color` on its cells where the foreground is the default (null) and a single underline where there is none. Cells a program styled are left alone. A row with no `://` is not touched.
- Consumes: `Terminal.paletteColor(12)` for the color (the theme's bright blue).

- [ ] **Step 1: Write the failing tests.** `src/vt.zig`, `test "markUrls colors a plain URL and nothing else"`: a row of cells for `see https://example.com/a?b=1. ok` gets the color and a single underline on exactly the cells of `https://example.com/a?b=1`, not on `see`, the trailing full stop or `ok`; a URL cell whose foreground the program set keeps it; a row with `ftp://x.org` and one with `https://` alone are untouched; a CJK character before the URL does not shift the colored cells (a wide character is two cells). `src/draw.zig`: a screen drawn with a URL in it differs from the same screen with `markUrls` disabled in the URL's cells (the blue appears) and is identical elsewhere, and `dirtyRows` reports the row dirty when a URL is typed into it.
- [ ] **Step 2: Run them, expect FAIL** (no `markUrls`).
- [ ] **Step 3: Implement** `markUrls` (build the row's UTF-8 with each cell's start offset, find `://`, look back for `https` or `http`, `urlEndFrom`, map byte offsets back to cells) and call it at the end of `Painter.gather` with the palette color.
- [ ] **Step 4: Run the filtered tests, the full `zig build test` and `macos/build-app.sh`, expect PASS.**
- [ ] **Step 5: Commit** `Plain URLs are colored (theme bright blue) and underlined`.

### Task 5: Cmd-hover highlight and pointing hand (core, painter, view)

**Files:**
- Modify: `src/vt.zig` (`linkSpanAt`), `src/draw.zig` (`Painter.highlight`), `src/capi.zig`, `include/harf.h`, `macos/Sources/Harf/TerminalView.swift`, `macos/Sources/Harf/main.swift`, `docs/phase6-manual-check.md`, `ARCHITECTURE.md`
- Test: `src/vt.zig`, `src/draw.zig`, `macos/Sources/Harf/main.swift`

**Interfaces:**
- Produces: `vt.LinkKind = enum { hyperlink, url, path }`, `vt.LinkSpan = struct { kind: LinkKind, row: u16, lo: u16, hi: u16 }` (columns inclusive) and `vt.Terminal.linkSpanAt(self, col: u16, row: u16) ?LinkSpan`: OSC 8 first (cells with the same URI), then a plain URL, then a path (the path with its `:line:col`, without trailing punctuation). Whether a file exists is not checked here.
- Produces: `Painter.highlight: ?struct { row: u16, lo: u16, hi: u16, color: Rgb }`, drawn as a translucent tint over those cells when their row is drawn (inside `drawRowRange`, so every draw of the row applies it exactly once); C `harf_painter_set_highlight(p, row, lo, hi, r, g, b)` and `harf_painter_clear_highlight(p)`; C `int harf_term_link_span_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint16_t *row, uint16_t *lo, uint16_t *hi)` returning 0 none, 1 hyperlink, 2 url, 3 path.
- Produces (Swift): `TerminalController.hoverLink(at: NSPoint) -> (row: Int, lo: Int, hi: Int)?` (only a link Cmd-click would open: an allowed OSC 8 link, an http(s) URL, or a file that exists), `TerminalView` hover state updated by `mouseMoved`, `flagsChanged`, `mouseExited` and each wake while a highlight is shown; the rows of the old and new highlight are invalidated; `resetCursorRects` adds the pointing hand over the highlight.

- [ ] **Step 1: Write the failing tests.** `src/vt.zig`: `linkSpanAt` on `see https://example.com/a. ok` (url, columns 4 to 25), on `at src/main.zig:12:5: error` (path, from `src` to the last `5`), on an OSC 8 link written with `ESC ] 8 ; ; url ESC \ text ESC ] 8 ; ; ESC \` (hyperlink, the cells of `text`), on a CJK-prefixed row (columns, not bytes), and on a space (null). `src/draw.zig`: with `highlight` set on a row, that row's pixels change inside the span and not outside it, and drawing the row twice in a row gives the same pixels (not darker). `macos/.../main.swift`: `hoverLink(at:)` on the 3c sample row gives the URL's columns, the existing file's columns, and nil for `ftp://` and a missing file; the view with `Command` held over the URL shows the highlight (pixel in the span differs from the same pixel with it cleared).
- [ ] **Step 2: Run them, expect FAIL.**
- [ ] **Step 3: Implement** as in the interfaces. A byte offset in a token maps to a column through the cell offsets `tokenAt` records.
- [ ] **Step 4: Run the full `zig build test`, `macos/build-app.sh` and the self-test, expect PASS.**
- [ ] **Step 5: Docs.** `docs/phase6-manual-check.md`: a "Cmd-click on paths and URLs" section: `editor = vscode://file{path}:{line}:{col}` and Cmd-click on `echo src/main.zig:12:5` opens VS Code there; relative paths resolve against the pane's directory (also after `cd`); a missing file, a directory and a plain word do nothing; without `editor` the file opens in TextEdit; "Choose Editor…" in the Harf menu shows the app picker, picking VS Code writes the template into the config and another app writes `app:` (no line number); a plain `https://example.com` is blue and underlined as printed and Cmd-click opens the browser, a trailing full stop is not part of it, `ftp://` is not colored; holding Cmd over a URL, an OSC 8 link or an existing file tints it and shows the pointing hand, releasing Cmd or moving away clears it. One decision-log row in `ARCHITECTURE.md`.
- [ ] **Step 6: Commit** `Cmd-hover tints the link under the pointer and shows the pointing hand; checklist and decision log`.

---

## Not in this plan

- Always-on coloring of file paths (existence needs the filesystem); a configurable link color; paths and URLs wrapped over two rows; bare `www.` text; `path(line,col)` and `path line N` forms; directories; a per-project editor.
