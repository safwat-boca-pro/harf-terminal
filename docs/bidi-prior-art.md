# Prior art: how terminals lay out Arabic / bidi (brief section 9.2)

Researched 2026-11-13 from source (GitHub, read via `gh api`) and the Terminal.app binary.
Everything below is quoted from code or comments unless marked **inference**.

## Result in one line

Every terminal with bidi support keeps the **cell grid authoritative** and maps logical cells to visual cells with a
per-row table. **None** lets natural glyph advances drive the layout (our model C). That is why cursor and selection are
straightforward for them and awkward for natural-advance layout.

## Per terminal

| Terminal | Shaping | Placement | Cursor / selection |
|---|---|---|---|
| **VTE** (GNOME Terminal) | FriBidi turns letters into Arabic **presentation-form characters**, one per cell. Lam-alef ligatures deliberately off (`bidi.cc`: "Don't do Arabic ligatures as per bug 142"). Comment says this should be replaced by HarfBuzz. | Each character drawn in its cell with the font's own advance. Spacing depends entirely on the font. | Per-row `log2vis`/`vis2log` arrays (`BidiRow`). |
| **Konsole** | Same family: `bidiMap(...)` returns `log2line`, `line2log`, `vis2line`, `shapemap`. | Cell-based. | `vis2log` macro used for hit-testing and drawing. |
| **iTerm2** | CTLine with an explicit paragraph direction; cell order derived from CTRun glyph positions; ligature-swallowed cells are placed left/right of their predecessor (`BidiDisplayInfo.swift`). | Per cell; CoreText offsets converted to within-cell offsets. No stretching or kashida code found. | One `lut` (logical to visual) per row with `visualForLogical` / `logicalForVisual`. Selection stored logically. Ink/Claude Code lines use absolute column moves and leave NUL holes, which are treated as spaces before bidi. |
| **WezTerm** | HarfBuzz per cluster. | Snaps at each cluster start (`phys(first_cell_idx) * cell_width`), natural advances inside the cluster. | Cursor is mirrored across the whole line. Source comment: `TODO: remember logical/visual mapping for selection`. Bidi is off by default. |
| **Terminal.app** | **Inference from imports/selectors, not decompiled:** it imports `CTLineCreateWithAttributedString`, `CTLineGetGlyphRuns`, `CTRunGet{Glyphs,Advances,StringIndices,StringRange,Attributes}`, `CTFontDrawGlyphsWithAdvances`, ICU `u_charMirror`/`u_isMirrored`; selectors `_glyphsBuffer`, `_advancesBuffer`, `attributedStringForLine:`, `displayCursorPosition` vs `cursorPosition`. | Looks like CTLine shaping, then drawing glyphs with its own computed advances. Whether it scales glyphs is **unknown**. | A separate display cursor position suggests a logical-to-display mapping. |
| **mlterm** | FriBidi + OpenType; not read in detail. | Cell-based. | Not read. |

## Selection: an open product question (iTerm2's own notes)

iTerm2's maintainers tested native macOS text and browsers with `سلام Hello دنیا` (`docs/bidi-selection-direction.md`):

- **TextEdit:** visual selection (highlight follows the pointer, stays contiguous), logical-order copy of what was swept.
- **Safari, Chrome, Firefox:** logical selection (highlight can go discontiguous; copy includes everything between the endpoints).
- macOS is therefore not consistent. iTerm2's maintainer leans to **visual mouse selection** and puts logical selection in a keyboard "copy mode". Their open PR implements the browser-style logical model.

## What REA could and could not do

The REA MCP server failed to start its Ghidra provider (and then `binary_session`), because `SDKROOT` is exported into its
environment and points at an SDK newer than the Swift toolchain it compiles a helper with. The Terminal.app findings above use
`otool`/`nm`/`strings` instead. Terminal.app's real glyph-placement code has **not** been decompiled.

## Sources

- iTerm2: `sources/Drawing/BidiDisplayInfo.swift`, `docs/bidi-selection-direction.md`, `sources/Drawing/iTermCoreTextLineRenderingHelper.m`
- VTE: `src/bidi.cc`, `src/bidi.hh`, `src/fonts-pangocairo.cc`
- WezTerm: `wezterm-gui/src/termwindow/render/screen_line.rs`
- Konsole: `src/terminalDisplay/TerminalPainter.cpp`
- Terminal.app: `/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal` (imports, strings)
