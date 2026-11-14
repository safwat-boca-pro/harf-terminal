# Settings Window and Self-Documenting Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Cmd+,` (`Harf -> Settings…`) opens a native two-tab macOS Settings window (**General** and **Keybindings**) with an **"Open Config File…"** button, backed by `~/.config/harf/config` as the single source of truth. The config file is kept self-documenting with `#` comments above every setting and default keybinding, and in-place updates preserve comments, `palette` lines, and custom `send:` bindings.

**Architecture:** Config file surgical editing and template seeding live in Zig (`src/config.zig`, exposed through `harf_config_*` in `src/capi.zig` and `include/harf.h`), following the rule "add capability in Zig, not Swift". The Swift shell (`macos/Sources/Harf/SettingsWindow.swift`, `Settings.swift`, `App.swift`) provides a pure AppKit `NSWindowController` with two tabs (**General** and **Keybindings**) that reads from `Settings.shared`, writes changes through the Zig config editor, and refreshes live when `ConfigWatcher` detects an external save.

**Tech Stack:** Zig 0.17.1 (`.tools/zig`), Swift 6 / AppKit.

## Global Constraints

- Add capability in Zig, not Swift; `include/harf.h` is hand-written and mirrors `src/capi.zig`.
- Idle cost zero: no timers or polling in the Settings window; live sync uses existing `ConfigWatcher` dispatch sources.
- Run Zig with `PATH=$PWD/.tools/zig:$PATH`; build with `macos/build-app.sh`; self-test is `macos/.build/Harf.app/Contents/MacOS/Harf --selftest`.
- Commit messages carry no attribution lines (user rule).

## Decisions (from `/grill-me` design review)

1. **Two-tab native Settings window (`Cmd+,`) + "Open Config File…" button:**
   - `Cmd+,` (`open_config`) opens the native Settings window instead of launching an external text editor directly.
   - An **"Open Config File…"** button in the Settings window footer (and a menu item `Harf -> Open Config File…`) opens `~/.config/harf/config` in the user's plain-text editor (`Settings.shared.openConfigFile()`).
2. **Self-documenting `~/.config/harf/config` with in-place updates:**
   - `config.template` in `src/config.zig` is expanded so every setting and every default `keybind` is listed with explanatory `#` comments.
   - When the GUI saves a change (or when `ensureConfigFile()` runs on an existing bare file that has no `#` comments), Zig seeds missing comment sections from `template` and updates `key = value` (or uncomments `# key = ...`) in place so `#` comments, `palette = ...` lines, and custom `send:` bindings are never lost.
3. **General tab controls:**
   - **Font:** Monospaced font family dropdown + size stepper/field (`6..72` pt).
   - **Theme:** Mode picker (`Dark`, `Light`, `Follow System`) + theme dropdown(s) populated with built-in `dark`, `light`, and any files in `~/.config/harf/themes/`.
   - **Color overrides:** Three `NSColorWell` pickers for `foreground`, `background`, and `cursor_color` (`#rrggbb`), plus a **"Reset to Theme"** button that clears/comments out the three color overrides so the active theme's colors apply.
   - **Scrollback, Clipboard, Notifications, Shell Integration:** Controls for `scrollback_bytes`, `clipboard_write` (`allow` / `deny`), `notifications` (`unfocused` / `always` / `off`), and `shell_integration` (`auto` / `off`).
4. **Keybindings tab controls:**
   - Table of all built-in actions with human-readable names and current triggers, plus read-only rows for any custom `send:` bindings (with a hint to use **"Open Config File…"** to edit raw bytes).
   - **Click a row to record a key combo:** `Escape` cancels recording; `Delete` / `Backspace` (with no modifiers) unbinds the action (`unbind`); **"Reset Defaults"** restores the built-in bindings.
   - **Conflict handling:** If a recorded key combo is already bound to another action, **block and warn** inline (naming the conflicting action) rather than silently reassigning it.

## Review Focus

- Updating a setting in place on an existing commented `~/.config/harf/config` preserves all `#` comments, `palette` lines, and `send:` keybinds.
- A bare `~/.config/harf/config` created by hand (with no `#` comments) gets merged into the commented template on first save or `ensureConfigFile()` without losing the user's active values.
- Recording a shortcut that conflicts with another bound action is rejected with a warning and leaves both bindings unchanged.
- Unbinding a default shortcut writes `keybind = <default_trigger> = unbind` so the default does not reappear on reload.
- Saving `~/.config/harf/config` in an external editor while the Settings window is open updates the Settings window controls automatically.

---

### Task 1: Expanded config template and comment-preserving Zig config writer

**Files:**
- Modify: `src/config.zig`, `src/capi.zig`, `include/harf.h`
- Test: `src/config.zig`, `src/capi.zig`

**Interfaces:**
- Produces in `src/config.zig`:
  - Expanded `pub const template` including commented-out lines for all default keybindings.
  - `pub fn applyEdit(a: Allocator, existing: []const u8, key: []const u8, value: ?[]const u8) ![]u8`:
    - If `existing` has no `#` comment lines, merges `existing`'s active lines onto `template` first so the file becomes self-documenting.
    - When `value` is non-null (`"16"`, `"dark:dark, light:light"`, `"#102030"`, etc.), replaces the active `key = ...` line in place, or uncomments and updates `# key = ...` in place, or appends `key = value`.
    - When `value` is `null` (used by **"Reset to Theme"** for `foreground`, `background`, `cursor_color`), re-comments `key = ...` back to `# key = <default>`.
  - `pub fn applyKeybindEdit(a: Allocator, existing: []const u8, action: []const u8, new_trigger: ?[]const u8) ![]u8`:
    - Updates the `keybind = ...` lines for `action` (inserting `keybind = <default_trigger> = unbind` when a built-in default trigger is unbound or moved to a different trigger).
    - When `action` is `"*"` and `new_trigger == null` (**"Reset Defaults"**), removes non-`send:` `keybind` overrides and re-comments the template's default `keybind` lines while preserving any custom `send:` lines.
  - C ABI in `src/capi.zig` and `include/harf.h`:
    - `harf_config_set(dir, key, value)` (null `value` resets/comments out the key)
    - `harf_config_set_keybind(dir, action, trigger)` (null `trigger` unbinds; `action = "*"` with null `trigger` resets default keybinds)
    - `harf_config_theme_raw(cfg, out, cap)` and optional color-override getters (`harf_config_fg_override`, `harf_config_bg_override`, `harf_config_cursor_override`) so the GUI knows whether `theme` is single vs `dark:A, light:B` and whether color overrides are set.

- [ ] **Step 1: Write the failing tests** in `src/config.zig` and `src/capi.zig`:
  - `test "every example line of the template is valid once uncommented"` covers the expanded default keybindings section.
  - `test "applyEdit preserves comments, uncomments template keys in place, and seeds comments into a bare file"`.
  - `test "applyEdit with null value re-comments foreground/background/cursor_color"`.
  - `test "applyKeybindEdit rebinds, unbinds defaults with unbind, and Reset Defaults keeps send: bindings"`.
- [ ] **Step 2: Run the filtered Zig tests, expect FAIL.**
- [ ] **Step 3: Implement** `applyEdit`, `applyKeybindEdit`, the expanded `template`, and the `harf_config_*` C ABI functions.
- [ ] **Step 4: Run `PATH=$PWD/.tools/zig:$PATH zig build test`, expect PASS.**
- [ ] **Step 5: Commit** `config: expand template comments and add comment-preserving in-place config writer`.

---

### Task 2: Two-tab AppKit Settings window (General + Keybindings)

**Files:**
- Create: `macos/Sources/Harf/SettingsWindow.swift`
- Modify: `macos/Sources/Harf/Settings.swift`, `macos/Sources/Harf/App.swift`, `macos/Sources/Harf/main.swift`, `docs/phase6-manual-check.md`, `ARCHITECTURE.md`
- Test: `macos/Sources/Harf/main.swift`

**Interfaces:**
- Produces `SettingsWindowController` (`@MainActor final class SettingsWindowController: NSWindowController`) with:
  - `NSTabView` containing two tabs: **General** and **Keybindings**.
  - **General tab:**
    - Font family `NSPopUpButton` (installed monospaced fonts) + font size `NSTextField` / `NSStepper` (`6..72` pt).
    - Theme mode `NSSegmentedControl` (`Dark`, `Light`, `Follow System`) + theme `NSPopUpButton`(s) listing `dark`, `light`, and `~/.config/harf/themes/*`.
    - Three `NSColorWell` controls (`Foreground`, `Background`, `Cursor`) + **"Reset to Theme"** button.
    - Scrollback size (`NSPopUpButton` / field), Clipboard (`Allow` / `Deny`), Notifications (`When Unfocused` / `Always` / `Off`), Shell Integration (`Auto` / `Off`).
  - **Keybindings tab:**
    - Table/stack of actions with shortcut badges; clicking a row enters recording mode (`Escape` cancels, `Delete`/`Backspace` unbinds).
    - Duplicate trigger check against `Settings.shared.bindings`: if another action already uses that trigger, refuses the change and displays an inline conflict warning naming the other action.
    - **"Reset Defaults"** button.
    - Read-only listing for custom `send:` bindings.
  - **Footer:** **"Open Config File…"** button (`Settings.shared.openConfigFile()`).
- Updates `AppDelegate.perform("open_config", ...)`: opens/focuses `SettingsWindowController.shared`; adds `"Open Config File…"` (`open_config_file`) to the `Harf` menu.

- [ ] **Step 1: Write the failing self-tests** in `macos/Sources/Harf/main.swift`:
  - Changing font size, theme mode, color overrides (+ Reset to Theme), clipboard, notifications, and shell integration through `Settings` / `SettingsWindowController` writes a commented `~/.config/harf/config` and updates `Settings.shared`.
  - Recording a free shortcut updates the binding and writes `keybind = ...` to disk; recording a trigger already used by another action is rejected with a conflict warning and leaves the existing binding intact; pressing `Delete` unbinds a default shortcut by writing `= unbind`; **"Reset Defaults"** restores default bindings while keeping `send:` bindings.
- [ ] **Step 2: Run `./macos/build-app.sh`, expect FAIL.**
- [ ] **Step 3: Implement** `SettingsWindow.swift`, wire `Settings.swift` and `App.swift`, and hook live reload updates into `SettingsWindowController`.
- [ ] **Step 4: Run `PATH=$PWD/.tools/zig:$PATH zig build test`, `./macos/build-app.sh`, and `macos/.build/Harf.app/Contents/MacOS/Harf --selftest`, expect PASS.**
- [ ] **Step 5: Docs.** Update `docs/phase6-manual-check.md` and `ARCHITECTURE.md`.
- [ ] **Step 6: Commit** `Settings window: two-tab General and Keybindings UI backed by commented ~/.config/harf/config`.
