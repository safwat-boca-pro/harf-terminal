# Settings Window and Self-Documenting Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Cmd+,` (`Harf -> Settings…`) opens a native two-tab macOS Settings window (**General** and **Keybindings**) with an **"Open Config File…"** button, backed by `~/.config/harf/config` as the single source of truth. The file is kept self-documenting with `#` comments for every setting and default keybinding, updated atomically in place by extending the existing Zig writer (`setKey`) and a trigger-based binding primitive (`setKeybind`), with all `#` comments, `palette` lines, and custom `send:` bindings preserved.

**Architecture:** All config parsing, template generation, seeding, and atomic editing live in Zig (`src/config.zig`, exposed through `harf_config_*` in `src/capi.zig` and `include/harf.h`), following the rule "add capability in Zig, not Swift". The Swift shell (`macos/Sources/Harf/SettingsWindow.swift`, `Settings.swift`, `App.swift`) presents a pure AppKit `NSWindowController` (`tabbingMode = .disallowed`) with **General** and **Keybindings** tabs that validates fonts/themes through Zig, writes changes on commit (never on every drag frame), avoids feedback loops on reload, and refreshes live when `ConfigWatcher` sees an external save.

**Tech Stack:** Zig 0.17.1 (`.tools/zig`), Swift 6 / AppKit.

## Global Constraints

- Add capability in Zig, not Swift; `include/harf.h` is hand-written and mirrors `src/capi.zig`.
- Idle cost zero: no timers or polling in the Settings window; live sync uses existing `ConfigWatcher` dispatch sources.
- Self-tests never touch the real `~/.config/harf/config`: every test uses a temp directory via `Settings.shared.load(directory:)` and cleans up after itself.
- Run Zig with `PATH=$PWD/.tools/zig:$PATH`; build with `macos/build-app.sh`; self-test is `macos/.build/Harf.app/Contents/MacOS/Harf --selftest`.
- Commit messages carry no attribution lines (user rule).

## Decisions (from `/grill-me` design review + plan review fixes)

1. **Native Settings window (`Cmd+,`) + "Open Config File…" button:**
   - `Cmd+,` (`open_config`, menu item `Harf -> Settings…`) opens the native two-tab Settings window instead of launching a text editor directly.
   - An **"Open Config File…"** button in the Settings window footer and `Harf -> Open Config File…` (`open_config_file`) open `~/.config/harf/config` in the user's plain-text editor (`Settings.shared.openConfigFile()`).
   - **Window & tab traps fixed:** Settings sets `window.tabbingMode = .disallowed`, and `AppDelegate.openWindow` / tab navigation target the active/last terminal window (`controller(of: NSApp.keyWindow)?.window ?? windows.last?.window`), never `NSApp.keyWindow` unconditionally, so `Cmd+T` / `Cmd+N` never attach a terminal tab to Settings.
2. **Extend `setKey` (one writer) + trigger-based `setKeybind` + first-save seeding:**
   - Extend existing `setKey` (`src/config.zig:360`) to take `value: ?[]const u8`:
     - Non-null `value`: edit the **last** active line for `key` (matching `parse` last-wins semantics); otherwise insert right after the key's **last** `# key =` example line; otherwise append; **never** change a comment line.
     - `null` `value` (used by **"Reset to Theme"** and clearing `editor`): delete all active lines for `key` cleanly (removing any `# foreground = <default>` mismatch problem when switching themes).
   - **Keybindings primitive is per-trigger (`setKeybind(text, trigger, action)` + `resetKeybinds(text)`):**
     - Matches active `keybind = ...` lines by canonical parsed trigger `(mods, key)` (last-wins), updates the last matching line or inserts after the `# keybind = ` section / appends; `action == null` removes override lines for that trigger; `action == "unbind"` writes `unbind` (used when unbinding a built-in default trigger).
     - **"Reset Defaults"** calls `resetKeybinds` ("delete every active non-`send:` `keybind` line"), preserving custom `send:` bindings and restoring all defaults (`font_larger`, `goto_tab:1..9`, etc.).
   - **Template & Seeding (`seedConfig`):**
     - `template` generates all 35 commented `# keybind = ...` default lines at `comptime` directly from `default_keybinds` (zero drift) and includes a template version marker comment (`# harf-template: 2`).
     - Opening Settings or clicking `"Open Config File…"` never rewrites an existing hand-written file. Seeding runs **on first Settings GUI save** (when the file lacks the template marker or has no active lines and is an untouched old template), keeping existing `setKey` and `Settings.shared.setEditor` behavior intact.
     - All file writes (`setKeyInFile`, `setKeybindInFile`, `resetKeybindsInFile`, `seedConfigInFile`) share one atomic helper (`writeFileAtomic`: write `{path}.harf-tmp` and `rename`).
3. **General tab controls (all config settings covered):**
   - **Font:** Family popup filtered by probing candidate monospaced fonts with `harf_painter_new_font` (never offers fonts CoreText refuses), plus size field/stepper (`6..72` pt).
   - **Theme (`Fixed` | `Follow System`):** Uses `harf_config_theme_name(cfg, dark)` (no `theme_raw` needed). Equal names show **`Fixed`** with one popup (`theme = A`); distinct names show **`Follow System`** with `Dark` and `Light` popups (`theme = dark:A, light:B`). Theme lists include `dark`, `light`, and `<configDir>/themes/*` filtered with `harf_config_safe_name`.
   - **Color overrides:** Three `NSColorWell` controls (`foreground`, `background`, `cursor_color`) backed by `harf_config_override(cfg, which, rgb)`, committing on release/end-edit rather than dragging every frame, plus **"Reset to Theme"** (`NULL` deletes the active override lines).
   - **Behavior:** `scrollback_bytes` and `shell_integration` (`auto` / `off`) explicitly labeled **"Applies to new windows, tabs, and panes"**; `clipboard_write` (`allow` / `deny`), `notifications` (`unfocused` / `always` / `off`), `paste_guard` (`on` / `off`).
   - **Editor (`Cmd-click` on paths):** Current template control + **"Choose App…"** (invokes `editorTemplate` / `NSOpenPanel` picker from `Editor.swift`) + **"Default Text Editor"** clear button (`NULL`).
   - **Re-entrancy guard:** `isRefreshing` suppresses control actions whenever reload updates the UI controls.
4. **Keybindings tab controls:**
   - Single bindable action catalog exported from Zig (`harf_config_action_count`, `harf_config_action_name`, adding `choose_editor` and `open_config_file` to `config.Action`, expanding `goto_tab:1..9`, excluding `send` and `none`), plus read-only rows for custom `send:` bindings (with an **"Open Config File…"** hint).
   - Rows represent each active binding `(action, arg, trigger)` plus `(Unbound)` rows for actions that currently have no active trigger, so unbinding one of `font_larger`'s two defaults or one `goto_tab:1..9` slot is unambiguous.
   - **Shortcut recorder:** Handles **both** `performKeyEquivalent` and `keyDown` while active (so `Cmd+W`, `Cmd+Q`, etc. are captured instead of hitting the menu). `Escape` cancels; `Delete` / `Backspace` without modifiers unbinds (`unbind` if the trigger is a built-in default, override removal otherwise). If a recorded key combo is already bound to another action, **block and warn** inline (naming the conflicting action).

## Review Focus

- Parsing any valid config before and after `seedConfig`, and after editing any setting back to its current value, yields an equal `Config` struct (verified by `expectEqualConfig`, not brittle string equality on reordered/seeded files).
- `setKey` handles multiple active lines for the same key (last-wins), commented `# key =` lines (leaves comments untouched, inserts after last `# key =`), and `value == null` (deletes active lines without inserting bogus `# fg = #ebebeb` defaults).
- Recording `Cmd+W` or `Cmd+Q` in the Keybindings tab captures the combo instead of closing Settings or quitting Harf; duplicate triggers are blocked with a warning.
- `Cmd+T` / `Cmd+N` pressed while Settings is the key window opens a terminal window/tab on the terminal window, never on Settings.
- Dragging in `NSColorWell` does not rewrite `~/.config/harf/config` on every drag frame, and an external edit to the config file updates an open `SettingsWindowController` cleanly via `ConfigWatcher` without writing back.

---

### Task 1: Zig config template generation, extended `setKey`, `setKeybind`, seeding, and C ABI

**Files:**
- Modify: `src/config.zig`, `src/capi.zig`, `include/harf.h`
- Test: `src/config.zig`, `src/capi.zig`

**Interfaces:**
- Produces in `src/config.zig`:
  - `pub const Action` adds `open_config_file` and `choose_editor`; `bindable_actions` list excludes `send` and `none`, expands `goto_tab:1`..`goto_tab:9`.
  - `Config.theme_names: [2][:0]const u8` (sentinel-terminated for direct C ABI return).
  - `pub const template: [:0]const u8`: includes `# harf-template: 2` marker and generates all commented `# keybind = ...` lines at `comptime` directly from `default_keybinds`.
  - `writeFileAtomic(path: [:0]const u8, text: []const u8) !void` (shared `{path}.harf-tmp` + `rename` writer).
  - Extended `pub fn setKey(gpa: Allocator, text: []const u8, key: []const u8, value: ?[]const u8) SetKeyError![]u8` and `setKeyInFile(gpa, path, key, value: ?[]const u8)`:
    - Non-null: rewrites last active `key = ...` line; else inserts after last `# key = ` example line; else appends; never alters `#` comment lines.
    - Null: deletes all active `key = ...` lines.
  - `pub fn seedConfig(gpa: Allocator, text: []const u8) Allocator.Error![]u8` and `seedConfigInFile(gpa, path)`:
    - If `text` already contains the marker, returns a copy untouched.
    - If `text` has zero active lines and lacks the marker (e.g. empty or old 26-line template), returns `template`.
    - Otherwise preserves all existing lines and appends documented `#` sections from `template` whose keys have neither `# key =` nor active `key =` lines, plus the marker comment.
  - `pub fn setKeybind(gpa: Allocator, text: []const u8, trigger: []const u8, action: ?[]const u8) SetKeyError![]u8` and `setKeybindInFile(gpa, path, trigger, action: ?[]const u8)`:
    - Uses `parseTrigger` to match canonical `(mods, key)` on active `keybind = ...` lines; non-null writes/rewrites last match (`insert after last # keybind =` / append); `null` deletes active lines for that trigger.
  - `pub fn resetKeybinds(gpa: Allocator, text: []const u8) Allocator.Error![]u8` and `resetKeybindsInFile(gpa, path)`: deletes every active non-`send:` `keybind` line.
- Produces in `src/capi.zig` and `include/harf.h`:
  - `int harf_config_set_key(const char *path, const char *key, const char *value)` (`value` nullable -> `NULL` deletes active lines).
  - `int harf_config_seed(const char *path)`.
  - `int harf_config_set_keybind(const char *path, const char *trigger, const char *action)` (`trigger == NULL` resets all non-`send:` keybinds; `action == NULL` removes override for `trigger`).
  - `const char *harf_config_theme_name(HarfConfig *cfg, int dark)`.
  - `int harf_config_override(HarfConfig *cfg, int which, uint8_t rgb[3])` (`which`: `0` fg, `1` bg, `2` cursor; returns `1` if set, `0` if unset).
  - `int harf_config_safe_name(const char *name)`.
  - `size_t harf_config_action_count(void)` and `const char *harf_config_action_name(size_t i)`.

- [ ] **Step 1: Write the failing tests** in `src/config.zig` and `src/capi.zig`:
  - Expand `test "every example line of the template is valid once uncommented"` to also verify that uncommenting the template's keybind lines matches `default_keybinds`.
  - Extend `test "setKey ..."` to cover multiple active lines (last-wins), inserting right after the last `# key = ...` example line inside a multi-section file without altering comments, and `value == null` deleting active lines.
  - Add `test "seedConfig round-trip preserves Config equality"` with `expectEqualConfig(a, b)`: verify empty, old 26-line template, and hand-written config (`font_size = 18`, `theme = mine`, `palette = 1=#ff5555`, `foreground = #abcdef`, custom comment, custom `send:` keybind) parse identically before and after `seedConfig`, and after writing back current values.
  - Add `test "setKeybind and resetKeybinds"` covering canonical trigger matching (`Command+T` vs `cmd+t`), updating last matching line, `null` removing override, `"unbind"` unbinding a default, and `resetKeybinds` removing all non-`send:` active keybinds while keeping `send:` and comments.
  - Add C ABI test covering `harf_config_set_key(..., NULL)`, `harf_config_seed`, `harf_config_set_keybind`, `harf_config_theme_name`, `harf_config_override`, `harf_config_safe_name`, and `harf_config_action_*`.
- [ ] **Step 2: Run filtered Zig tests, expect FAIL.**
- [ ] **Step 3: Implement** the Zig functions, comptime template keybinds, C exports, and header declarations.
- [ ] **Step 4: Run `PATH=$PWD/.tools/zig:$PATH zig build test`, expect PASS.**
- [ ] **Step 5: Commit** `config: extend setKey/setKeybind, seed docs atomically, and expose Settings C ABI`.

---

### Task 2: Settings window shell, AppKit fixes, General tab, and live sync

**Files:**
- Create: `macos/Sources/Harf/SettingsWindow.swift`
- Modify: `macos/Sources/Harf/Settings.swift`, `macos/Sources/Harf/App.swift`, `macos/Sources/Harf/Editor.swift`, `macos/Sources/Harf/main.swift`
- Test: `macos/Sources/Harf/main.swift`

**Interfaces:**
- Modifies `App.swift`:
  - Harf menu becomes `("Harf", [("Settings…", "open_config"), ("Open Config File…", "open_config_file"), ("Choose Editor…", "choose_editor"), ("Reload Config", "reload_config"), ("Quit Harf", "quit")])`.
  - `open_config` shows `SettingsWindowController.shared`; `open_config_file` calls `Settings.shared.openConfigFile()`.
  - `openWindow(tab:argv:content:)` and `next_tab`/`prev_tab`/`goto_tab` target `controller(of: NSApp.keyWindow)?.window ?? windows.last?.window` so `Cmd+T`/`Cmd+N` never target the Settings window.
- Modifies `Settings.swift`:
  - Reads and exposes `themeNameDark`, `themeNameLight`, `fgOverride: [UInt8]?`, `bgOverride: [UInt8]?`, `cursorOverride: [UInt8]?`, and `var onReload: [ObjectIdentifier: @MainActor () -> Void]` callbacks.
  - Adds `monospacedFontFamilies()` (probing candidate fixed-pitch families via `harf_painter_new_font` / `harf_painter_free`), `availableThemes()` (`["dark", "light"]` + `<dir>/themes/*` passing `harf_config_safe_name`), `availableActions()` (from `harf_config_action_count` / `harf_config_action_name`), and `defaultBindings()`.
  - Adds `editSetting(_ key: String, value: String?) -> Bool` (ensures directory/file exists without rewriting existing bare/old files before write, calls `harf_config_seed` on first GUI save, then `harf_config_set_key` and `load()`). Keeps `setEditor(_:)` calling `harf_config_set_key` directly so existing self-test `3d` stays intact; adds optional `seedFirst: Bool = false` or calls `editSetting("editor", ...)` from Settings UI.
- Produces `SettingsWindowController` (`@MainActor final class SettingsWindowController: NSWindowController`) in `SettingsWindow.swift`:
  - `window.tabbingMode = .disallowed`, `window.isReleasedWhenClosed = false`.
  - `NSTabView` with **General** and **Keybindings** (Keybindings populated in Task 3), plus footer **"Open Config File…"** button (`Settings.shared.openConfigFile()`).
  - **General tab** controls with `isRefreshing` re-entrancy guard:
    - Font family popup (`monospacedFontFamilies()`) + font size field/stepper (`6..72`).
    - Theme mode `Fixed | Follow System` + one popup (`Fixed`) or `Dark`/`Light` popups (`Follow System`).
    - Three `NSColorWell`s (`Foreground`, `Background`, `Cursor`) committing on drag release / color commit (via `NSColorPanel.shared.isContinuous = false` or commit tracking on `mouseUp`/close, not writing disk on `.leftMouseDragged`), plus **"Reset to Theme"** (`nil` for all three keys).
    - Scrollback popup/field + Shell Integration toggle (`auto`/`off`), both clearly labeled `"Applies to new windows, tabs, and panes"`.
    - Clipboard (`allow`/`deny`), Notifications (`unfocused`/`always`/`off`), Paste Guard (`on`/`off`), Editor template field/label + **"Choose App…"** + **"Default"**.
    - Live sync subscriber in `Settings.shared.onReload` refreshing General controls with `isRefreshing = true`.

- [ ] **Step 1: Write the failing self-tests** in `macos/Sources/Harf/main.swift` (all using temp dirs via `Settings.shared.load(directory:)`, never `~/.config/harf/config`):
  - `monospacedFontFamilies()` never contains a family rejected by `harf_painter_new_font` and excludes proportional fonts like `"Helvetica"`; `availableThemes()` filters invalid names like `".DS_Store"` or `"bad theme"`.
  - Window/tab fix: when a `WindowController` exists and an unrelated/Settings `NSWindow` (`tabbingMode = .disallowed`) is `keyWindow`, `AppDelegate.openWindow(tab: true)` tabs onto the terminal window, never the Settings window.
  - General tab & first-save seeding: opening `SettingsWindowController` on a bare `"font_size = 15\n"` config file leaves the file untouched on disk; changing `Notifications` / `Theme` / `Font` / `Paste Guard` / `Editor` / color override writes a seeded, commented config file preserving `font_size = 15`; **"Reset to Theme"** deletes active `foreground`/`background`/`cursor_color` lines cleanly; re-entrancy guard prevents `refreshFromSettings()` from firing writes.
  - **Live-reload test:** While `SettingsWindowController` is open on a temp config directory, writing an external change (e.g. `font_size = 19\ntheme = light\n`) directly to disk causes `ConfigWatcher` + `pump(5, until: ...)` to update `Settings.shared` and the General tab controls automatically without rewriting the file.
- [ ] **Step 2: Run `./macos/build-app.sh`, expect FAIL.**
- [ ] **Step 3: Implement** `SettingsWindow.swift` (window shell + General tab + live sync) and wire `Settings.swift`, `App.swift`, `Editor.swift`.
- [ ] **Step 4: Run `PATH=$PWD/.tools/zig:$PATH zig build test`, `./macos/build-app.sh`, and `macos/.build/Harf.app/Contents/MacOS/Harf --selftest`, expect PASS.**
- [ ] **Step 5: Commit** `Settings window: General tab, comment seeding on save, live sync, and tab-target fixes`.

---

### Task 3: Keybindings tab, shortcut recorder, and docs

**Files:**
- Modify: `macos/Sources/Harf/SettingsWindow.swift`, `macos/Sources/Harf/Settings.swift`, `macos/Sources/Harf/App.swift`, `macos/Sources/Harf/main.swift`, `docs/phase6-manual-check.md`, `ARCHITECTURE.md`
- Test: `macos/Sources/Harf/main.swift`

**Interfaces:**
- Produces in `SettingsWindow.swift`:
  - Keybindings tab listing every active `(action, arg, trigger)` row plus `(Unbound)` rows for every bindable action in `Settings.shared.availableActions()` that currently has no active binding, plus read-only rows for custom `send:` bindings (with an **"Open Config File…"** hint).
  - `ShortcutRecorderView` (custom `NSView` becoming first responder when a row is clicked):
    - Overrides **both** `performKeyEquivalent(with:)` and `keyDown(with:)` while recording.
    - `Escape` cancels recording.
    - Unmodified `Delete` / `Backspace` unbinds the row's specific trigger (`"unbind"` if that trigger is in `Settings.shared.defaultBindings()`, `nil` to delete user override otherwise).
    - Converts recorded key via `Trigger(event)`; formats trigger string (using `cmd+...`, `ctrl+...`, `option+...`, `shift+...`) and rejects bare single printable keys without modifiers.
    - **Conflict blocking:** Checks `Settings.shared.bindings` for another row already using the recorded `Trigger`; if present (and not already bound to the exact same `(action, arg)`), rejects the change, keeps both bindings untouched, and shows an inline warning naming the conflicting action.
  - **"Reset Defaults"** button: calls `harf_config_seed` (if needed) + `harf_config_set_keybind(path, nil, nil)` and reloads.
- Updates `AppDelegate.perform` to handle `"choose_editor"` and `"open_config_file"`, and updates `docs/phase6-manual-check.md` + `ARCHITECTURE.md`.

- [ ] **Step 1: Write the failing self-tests** in `macos/Sources/Harf/main.swift` (using temp dirs via `Settings.shared.load(directory:)`):
  - Keybindings list includes `choose_editor` and `open_config_file`, shows both `font_larger` defaults, and keeps an unbound action (`close` after unbinding) visible as unbound.
  - Recording `Cmd+W` via `performKeyEquivalent` on `ShortcutRecorderView` captures `cmd+w` instead of closing the Settings window.
  - Recording a trigger already bound to another action (e.g. trying to bind `close` to `cmd+t`) fails with an inline conflict message naming `new_tab` and leaves both bindings unchanged.
  - Rebinding a single `font_larger` trigger leaves the second `font_larger` trigger (`cmd+shift+=`) intact; unbinding a default writes `keybind = <trigger> = unbind`; unbinding a custom trigger removes its line cleanly; **"Reset Defaults"** removes non-`send:` overrides, restores defaults, and keeps custom `send:` lines intact.
  - External edit adding/changing a `keybind` in the temp file updates the Keybindings rows via `pump(5, until: ...)`.
- [ ] **Step 2: Run `./macos/build-app.sh`, expect FAIL.**
- [ ] **Step 3: Implement** Keybindings tab + `ShortcutRecorderView` + conflict checking + Reset Defaults + live refresh.
- [ ] **Step 4: Run `PATH=$PWD/.tools/zig:$PATH zig build test`, `./macos/build-app.sh`, and `macos/.build/Harf.app/Contents/MacOS/Harf --selftest`, expect PASS.**
- [ ] **Step 5: Docs.** Update `docs/phase6-manual-check.md` (`Configuration` section: `Cmd+,` opens Settings, `Open Config File…` opens `~/.config/harf/config` with comments preserved, Fixed/Follow System theme, color pickers + Reset to Theme, Keybindings recording/conflict/unbind/Reset Defaults) and add a decision-log row in `ARCHITECTURE.md`.
- [ ] **Step 6: Commit** `Keybindings tab: shortcut recorder, conflict guard, unbind/reset, and manual checklist`.
