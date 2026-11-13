# Harf architecture

Harf is a macOS (Apple Silicon) terminal emulator, Arabic/bidi-correct from day 1.
Zig core, thin Swift/AppKit shell, CPU-drawn (CoreGraphics/CoreText). Full design: `PROJECT_BRIEF.md`.

```
PTY (child shell)
  -> VT parser + screen/grid (libghostty-vt, logical order, damage-tracked)
    -> per-row layout: bidi (UAX #9) -> shaping (CoreText) -> cluster-to-cell map   [RTL rows only]
      -> draw (Zig, CoreText glyph runs into a CGContext passed over the Harf C ABI, include/harf.h)
        -> Swift/AppKit shell: view + dirty-rect invalidation, window, tabs, menus, IME, notifications
```

## Split

- **Zig core** (`src/`): PTY, screen/scrollback (via libghostty-vt), layout (bidi + shaping), drawing into a CGContext, selection/cursor logic, config. Builds `libharf.a`.
- **Swift shell** (`macos/`): windows, tabs/splits, menus, input + IME, the view and dirty-rect invalidation, notifications, session restore. Sees only `include/harf.h`.
- **C ABI** (`include/harf.h`, hand-written, mirrors `src/capi.zig`): small and stable. Add capability in Zig, not in Swift.

## Rules

- The grid stays in **logical order**; reordering happens at display time through a per-row logical<->visual map. Copy always yields logical text.
- Rows with no RTL code points skip bidi and shaping (plain-terminal fast path).
- Idle cost is zero: no timers, no display link while idle; the view redraws only dirty rects on demand.
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
| 2026-11-13 | Owner chose cell **model C** (natural word shapes) but rejected its uneven spacing, cursor and selection as built. Fixed as "C fit" (`docs/cell-model.md`); prior art in `docs/bidi-prior-art.md`. |
| 2026-11-13 | Owner: **30 MB `phys_footprint` target and a CPU-drawn renderer (no Metal)**. Corrected measurements: CPU view 25 MB vs Metal 30 MB at 80x24-class size; Terminal.app is ~50 MB at its default window (an earlier 17 MB figure was a run with no window). See `docs/perf.md`. |
| 2026-11-13 | Spike renderer switched from Metal + atlas to CPU drawing (Zig draws into a CGContext). Model D 'C fit' built: per-word kashida fit, per-cluster extents, ligature split. See `docs/cell-model.md`. The Metal spike was never committed; a copy exists only in the session scratchpad. |
| 2026-11-13 | Owner: mouse selection is **visual** (contiguous highlight), copy yields logical-order text like a text editor. REA server re-registered with an explicit Xcode `SDKROOT` (needs `/mcp` reconnect). |

## Open checks (from the brief's section 9)

- Whether libghostty-vt's stability guarantee covers its Zig module or only the C ABI (plan: C API only).
- What `-Demit-lib-vt` fetches; license audit before adoption.
- Name conflict check ("harf" is the root of HarfBuzz) before the first public commit.
