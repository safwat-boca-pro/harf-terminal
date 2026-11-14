# Harf

A fast, lightweight terminal emulator for macOS (Apple Silicon) with Arabic and bidirectional (bidi) text support from day one.

Harf pairs a **Zig** core (PTY, VT parser/grid, UAX #9 bidi, CoreText shaping, CoreGraphics drawing) with a thin **Swift/AppKit** shell.

## Features

- **Arabic & Bidi Rendering**:
  - Own Unicode Bidirectional Algorithm (UAX #9) implementation in Zig, tested against Unicode 18.0.0 conformance suites.
  - CoreText contextual shaping, ligatures, tashkeel, and system font fallback.
  - Logical-order grid with per-row logical-to-visual mapping — copying text always yields logical order.
  - Plain LTR rows skip bidi and shaping entirely.
- **Lightweight & Responsive**:
  - CPU-drawn via CoreGraphics and CoreText (no Metal, no web view), ~25–26 MB memory footprint.
  - Dirty-row tracking and batched glyph drawing; zero timers while idle.
- **Native macOS Shell**:
  - Windows, native tabs, and split panes (`Cmd+D` / `Cmd+Shift+D`).
  - Find bar (`Cmd+F`) across scrollback and active screen with all visible matches highlighted.
  - Editor-style cursor/edit shortcuts (`Option+Left/Right`, `Option+Backspace/Delete`, `Cmd+Left/Right`).
  - OSC 8 clickable links (`Cmd+Click`), OSC 52 clipboard writes (gated to the focused pane), and OSC 9/777 notifications.
- **Shell Integration (OSC 133)**:
  - Bundled `zsh` integration (`shell_integration = auto` by default) for prompt jumping (`Cmd+Up` / `Cmd+Down`), selecting the last command's output (`Cmd+Shift+A`), tab running indicators, and completion notifications for long-running commands.
- **Live Configuration**:
  - Plain `key = value` config with automatic hot reload on save, custom themes, system dark/light appearance tracking, and customizable keybindings.

## Requirements

- **OS**: macOS 14.0+ on Apple Silicon (`aarch64`)
- **Zig**: `0.17.1` (pinned in [`.zig-version`](.zig-version))
- **Xcode / Swift**: Swift 6.0+ toolchain

## Building & Running

Build the Zig static library, link the Swift shell, and assemble `macos/.build/Harf.app`:

```sh
./macos/build-app.sh
open macos/.build/Harf.app
```

> **Note:** `macos/build-app.sh` uses `.tools/zig/zig` if present, otherwise `zig` from `PATH`.

### Running Tests

Run the Zig test suite (includes UAX #9 conformance, shaping, VT/PTY, and config tests):

```sh
zig build test
```

On the first run, `test/fetch-ucd.sh` downloads the pinned Unicode 18.0.0 data files into `test/ucd/` and verifies their SHA-256 checksums.

To build only the Zig static library (`zig-out/lib/libharf.a`):

```sh
zig build
```

## Configuration

Harf reads its configuration from `$XDG_CONFIG_HOME/harf/config` (default `~/.config/harf/config`) and reloads automatically when saved. Press `Cmd+,` to open (or create) the commented default config file.

Example `~/.config/harf/config`:

```ini
font_family = Menlo
font_size = 14

# Default content size for new windows, in points
# window_width = 700
# window_height = 420

# Built-in themes: dark, light, or files in ~/.config/harf/themes/
theme = dark:dark, light:light

# Optional color overrides (#rrggbb)
# foreground = #ebebeb
# background = #0f0f12
# cursor_color = #ebebeb
# palette = 1=#ff5555

scrollback_bytes = 1048576
clipboard_write = allow       # allow | deny (reads are never allowed)
notifications = unfocused     # unfocused | always | off
shell_integration = auto      # auto | off

# Custom keybindings (use `unbind` to remove a default, or `send:TEXT` to send bytes)
# keybind = cmd+t = new_tab
# keybind = cmd+w = unbind
```

### Default Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+N` / `Cmd+T` / `Cmd+W` | New window / New tab / Close pane or tab |
| `Cmd+D` / `Cmd+Shift+D` | Split right / Split down |
| `Cmd+]` / `Cmd+[` | Focus next / previous pane |
| `Cmd+Shift+]` / `Cmd+Shift+[` | Next / previous tab (`Cmd+1`–`9` to jump) |
| `Cmd+F` / `Cmd+G` / `Cmd+Shift+G` | Find / Next match / Previous match |
| `Cmd+K` / `Ctrl+L` | Clear screen & scrollback / Clear visible screen |
| `Cmd+Up` / `Cmd+Down` | Jump to previous / next prompt (OSC 133) |
| `Cmd+Shift+A` | Select last command output (OSC 133) |
| `Cmd+=` / `Cmd+-` / `Cmd+0` | Increase / decrease / reset font size |
| `Cmd+,` / `Cmd+Shift+,` | Open config / Reload config |

## Architecture

```
PTY (child shell)
  -> VT parser + screen/grid (libghostty-vt, logical order, damage-tracked)
    -> Per-row layout: bidi (UAX #9) -> shaping (CoreText) -> cluster-to-cell map [RTL rows only]
      -> Draw (Zig, CoreText/CoreGraphics into a CGContext over include/harf.h)
        -> Swift/AppKit shell: view + dirty-rect invalidation, windows, tabs, splits, IME, notifications
```

- [`src/`](src/) — Zig core (`libharf.a`)
- [`include/harf.h`](include/harf.h) — Hand-written C ABI matching [`src/capi.zig`](src/capi.zig)
- [`macos/`](macos/) — Swift/AppKit shell and `build-app.sh`
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Architecture rules and decisions log

## License & Acknowledgments

Harf is licensed under the [MIT License](LICENSE).

- Terminal VT parser and grid state are powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) (1.0.1, MIT License).
- Bidi tables and conformance tests use data from the Unicode Character Database (18.0.0). See [NOTICE](NOTICE) for full third-party notices.
