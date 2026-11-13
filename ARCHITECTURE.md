# Harf architecture

Harf is a macOS (Apple Silicon) terminal emulator, Arabic/bidi-correct from day 1.
Zig core, thin Swift/AppKit/Metal shell. Full design: `PROJECT_BRIEF.md`.

```
PTY (child shell)
  -> VT parser + screen/grid (libghostty-vt, logical order, damage-tracked)
    -> per-row layout: bidi (UAX #9) -> shaping (CoreText) -> cluster-to-cell map   [RTL rows only]
      -> glyph atlas (rasterized via CoreText, cached)
        -> frame snapshot (cell instances + atlas updates) over the Harf C ABI (include/harf.h)
          -> Swift/AppKit shell: Metal draw, window, tabs, menus, IME, notifications
```

## Split

- **Zig core** (`src/`): PTY, screen/scrollback (via libghostty-vt), layout (bidi + shaping), glyph atlas, selection/cursor logic, config. Builds `libharf.a`.
- **Swift shell** (`macos/`): windows, tabs/splits, menus, input + IME, Metal pipeline, notifications, session restore. Sees only `include/harf.h`.
- **C ABI** (`include/harf.h`, hand-written, mirrors `src/capi.zig`): small and stable. Add capability in Zig, not in Swift.

## Rules

- The grid stays in **logical order**; reordering happens at display time through a per-row logical<->visual map. Copy always yields logical text.
- Rows with no RTL code points skip bidi and shaping (plain-terminal fast path).
- Idle cost is zero: no timers, no display link while idle (`MTKView` is paused and redraws on demand).
- Swift never sees libghostty headers; libghostty-vt sits behind a thin Zig wrapper so the grid stays swappable.

## Decisions log

| Date | Decision |
|---|---|
| 2026-11-12 | Name **Harf**; C prefix `harf_`; license **MIT**; min macOS **14**. |
| 2026-11-12 | Zig pinned to **0.17.1** (`.zig-version`, `build.zig.zon`). |
| 2026-11-12 | Reuse **libghostty-vt 1.0.1** (MIT, stable C ABI) for parser/screen via its C API, pending a Phase 3 spike (license audit, RTL-row access, throughput). Fallback: own parser. |
| 2026-11-12 | Header hand-written; app built with SwiftPM + `macos/build-app.sh` (no XcodeGen/Tuist). |
| 2026-11-13 | Local Zig comes from the official tarball in git-ignored `.tools/zig` (SHA-256 checked against ziglang.org's index), because the Homebrew download kept resetting. CI still uses brew. |
| 2026-11-13 | `build-app.sh` unsets `SDKROOT`: a shell-exported SDK newer than the selected Swift toolchain breaks the build ("this SDK is not supported by the compiler"). |
| 2026-11-13 | Zig target defaults to aarch64-macos with `os_version_min` 14.0, matching the Swift package. |

## Open checks (from the brief's section 9)

- Whether libghostty-vt's stability guarantee covers its Zig module or only the C ABI (plan: C API only).
- What `-Demit-lib-vt` fetches; license audit before adoption.
- Name conflict check ("harf" is the root of HarfBuzz) before the first public commit.
