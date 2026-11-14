# Cmd-click on `path:line:col` (design; the owner uses VS Code)

Spec source: `PROJECT_BRIEF.md` §6, "Cmd-click on `path:line:col` opens in the user's editor (configurable command)". A small change: this is the short design. The owner answered "vscode" to the question of which editor to build and try it with; the design below was presented first and not objected to.

## Intent and why

Compiler errors, test failures, `grep -n` and stack traces print `path:line:col`. Cmd-clicking one should open that file at that line in the editor the user works in, as Cmd-click already opens an OSC 8 link.

## Goals

- Cmd-click on a path token opens it: absolute, `~/...` or relative (resolved against the pane's current directory), with an optional `:line` and `:col` (`src/a.zig:12:5:` as compilers print it).
- Only a file that exists is opened (a click on any other word does nothing).
- `editor = ...` in the config says how, as a template with `{path}`, `{line}`, `{col}` (line and col are 1 when the text has none):
  - a URL template (`vscode://file/{path}:{line}:{col}`): opened with the system, values percent-encoded. Works for VS Code, Cursor (`cursor://`), Zed (`zed://`) with no `code` command installed and when the editor is already running;
  - a command template (`code --goto {path}:{line}:{col}`): split on spaces, then values substituted, run **without a shell** through the user's login shell as `exec "$@"` so `code` is found on the PATH.
- No `editor` set: the file opens in the default plain-text editor (no line number).
- Added by the owner after the first design (2026-11-14): **plain `http://` and `https://` text opens in the browser** (most programs print URLs without OSC 8), and **the editor can be chosen from the system**: Harf menu "Choose Editor…" shows the app picker and writes the `editor = ...` line to the config file (the file stays the one source of truth; hand-editing works as before). VS Code, VS Code Insiders, VSCodium and Cursor get their line-aware URL template; any other app gets `editor = app:/Applications/Name.app`, which opens the file in that app without a line number.
- Cmd-click order: OSC 8 link, then plain URL, then path, then the normal click. Works while a program tracks the mouse, like links.

## Non-goals and anti-goals

- Plain URLs: only `http` and `https` (the same allowlist as OSC 8); no `file:`, `ftp:`, `mailto:` text. No bare `www.` or `example.com` without a scheme.
- No hover underline or pointer cursor (links have none either). No path that wraps across two rows. No `path(line,col)` or `path line 12` forms. No directories.
- Anti-goal: opening something that runs. A path in terminal output can name an `.app` or a `.command` script; the default must never launch it (it opens as text), and a hostile filename (`;`, `$(...)`, quotes, spaces) must reach the editor as one argument, never through a shell command line.

## Constraints

- The path finder is Zig (capability in the core, not Swift); `include/harf.h` mirrors `src/capi.zig`.
- The row's text is the logical text; column positions come from cells (wide characters take two columns).
- The file name came from a program: it is checked for existence, not trusted.

## Approaches considered

1. **System "open" on any existing file.** Simplest, but it launches apps and scripts. Rejected.
2. **Only a command template.** The brief's wording, but a GUI app's PATH usually lacks `code`, and `code` ignores a running window's arguments in some setups. Needed as a second form, not the only one.
3. **URL template or command template, default text editor** (chosen). Works for VS Code out of the box through its URL scheme, supports any other editor by command, and is safe by default.

## Design

- Core, plain URLs: `vt.Terminal.urlAt(col, row, out) ?usize`: the run of cells around the click bounded by whitespace and `" ' ` < >`, from the last `http://` or `https://` (any case) at or before the click, trailing `.,;:!?` removed and a trailing `)` `]` `}` removed only while unbalanced; null if the click is before the URL's start, the URL is just the scheme, or it does not fit. C: `harf_term_url_at`.
- Core: `vt.Terminal.pathAt(col, row, out) ?PathRef { len, line, col }`: the run of non-space cells around the click (not crossing `" ' ` < > ( ) [ ] { } | , ;` ), trailing `.`, `:` and the like removed, an optional `:line` and `:col` read off the end. Null if the click is on blank, the token is empty, or the path does not fit `out` (never cut off). C: `harf_term_path_at`.
- Swift: `TerminalController.pathTarget(at:) -> PathTarget?` resolves (`~`, relative to the pane's directory) and checks it is a regular file. `editorLaunch(template:path:line:col:) -> EditorLaunch` (`.textEditor`, `.url`, `.command`) is a pure function. `openPath` (overridable, like `confirmPaste`) launches. `mouseDown` calls it after the OSC 8 check.
- Config: `editor = <template>` (default empty): a URL template, a command template, or `app:<path to an .app>` (open the file in that app). The VS Code line is the example in the generated config.
- Picker: `Settings.setEditor(_:)` rewrites the `editor` line in the config file (replacing the existing one, or appending), a pure `configText(_:settingEditor:)` function does the text change; `editorTemplate(forBundleID:appPath:)` maps an app to its template (known bundle ids: `com.microsoft.VSCode` to `vscode://file/{path}:{line}:{col}`, `com.microsoft.VSCodeInsiders` to `vscode-insiders://file/...`, `com.visualstudio.code.oss` and `com.vscodium` to `vscodium://file/...`, `com.todesktop.230313mzl4w4u92` (Cursor) to `cursor://file/...`; anything else `app:<path>`); the menu item runs `NSOpenPanel` on `/Applications`, `.app` bundles only.

## Left to the builder

Exact delimiter set at the edges, how failures to launch are reported (stderr line `harf: editor: ...` is enough), the checklist wording.
