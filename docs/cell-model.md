# Cell model (Phase 1 spike)

**Decision (2026-11-13): model C, built as "C fit" (see the last section), accepted by the owner for Phase 1.**
Plain C was rejected (uneven word spacing, cursor, selection); C fit fixes those.
Font policy for v1: keep CoreText's fallback cascade, no hardcoded Arabic font (brief 9.8 stands).
Typing alignment at the prompt (word re-fits per keystroke, first letter drifts): **Phase 4 status (2026-11-14)**: the grid draws with
this model and the cursor sits on its logical cell, so the drift is still there; pictures in `docs/phase4/typing-prompt.png` and
`typing-bare.png` (one frame per letter). Open: whether the drift is acceptable, any other cursor rule, ink centering, and per-paragraph bidi across soft wraps.
Observations below are the implementer's, not the owner's judgement.

## What exists

- Zig shapes each row with CoreText (`src/shape/layout.zig`), builds the **logical-to-visual cell map**
  (clusters: base letter + tashkeel; lam-alef is one glyph over two cells), rasterizes glyphs into an
  A8 atlas (`src/atlas.zig`), and returns GPU instances over the C ABI (`harf_spike_*`).
- Swift uploads the atlas and draws with Metal (`macos/Sources/Harf/`), in a window or to PNG.
- Visual order in the spike comes from **CoreText's bidi, not our UAX #9** (Phase 2). The cell map is the part that survives.
- Base direction: per row, first strong character (auto); the box row is forced LTR so it does not mirror.
- Pages are 3 panels (models A, B, C) x the section 4.7 strings, for 4 fonts x 11/14/20 pt at 2x.
  The 14 pt pages also exist with a cell-grid overlay.

View them: `docs/cell-model/*.png`, or `open macos/.build/Harf.app` (arrow keys: font and size, `g`: grid).
Regenerate: `macos/.build/Harf.app/Contents/MacOS/Harf --dump docs/cell-model`.

## The three models (section 4.3)

| | Rule | Parameters I chose (tunable) |
|---|---|---|
| A | Shape the run, put each cluster's glyph at its cell's left origin | none |
| B | A, then scale each glyph horizontally to fill its cell(s) and centre it | scale clamped to 0.75-1.35 |
| C | Natural advances inside a run; only the run's start edge snaps to its cell boundary | run scaled down uniformly if wider than its cells; RTL runs flush right, LTR flush left |

Tashkeel always keeps its CoreText offset from the base glyph (scaled with the base in B and C).

## Measured: Arabic is narrower than a monospace cell

Natural shaped width of the sample words divided by (letters x Menlo cell width), 14 pt at 2x (cell 17 px):

| Arabic font | average | per word min..max |
|---|---|---|
| Courier New | 0.84 | 0.25..0.99 |
| SF Arabic (system) | 0.64 | 0.43..0.96 |
| Geeza Pro | 0.58 | 0.41..0.78 |
| Al Nile | 0.49 | 0.33..0.69 |

A one-cell-per-letter grid gives Arabic 1.2x to 2x more room than these fonts want. Model B's 1.35 cap
can only close that for Courier New; for the others gaps remain by construction.
Row spacing in the pages is Menlo's cell height, so tall Arabic faces (Al Nile descent 15 px vs Menlo ~7 px at 14 pt) can touch the next row.

## Font fallback finding

With Menlo (or the monospaced system font) as primary, CoreText's Arabic cascade picks
**Courier New first**, then Geeza Pro (6th). SF Arabic is reachable only through the system UI font's cascade, not by name.
A naive "system fallback" therefore yields Courier New Arabic. Only Courier New among 31 installed
Arabic-capable families has the monospace trait. (This machine's font set; other Macs may differ.)

## Observations (implementer's, from the PNGs)

- Correct in all four fonts and all models: contextual forms, mixed-line visual order, lam-alef ligature,
  tashkeel attached to the right base and not clipped (shadda, damma, fatha), mirrored brackets in `(ناجح)`,
  Arabic-Indic digits, box row `│ مرحبا    │` keeps its bars in place.
- **A:** joins are broken in every proportional font. Words fall apart into spaced letters. SF Arabic's medial forms
  (ن ت ي) are short strokes, so dots look detached.
- **B:** best join continuity of the grid-perfect options, with residual gaps where the clamp bites.
  Glyph widths are visibly uneven (some stretched, some squeezed).
- **C:** best-looking words (the font's own shapes and joins), but spacing between words is uneven because each
  word is narrower than its cells; columns stay aligned only at run edges.
- Courier New is closest to the grid in every model (it is the only monospace-designed Arabic face), but its letterforms
  are the plainest.

## Open decisions (owner)

1. Which model, or a variant (e.g. B with a wider clamp, B with uniform per-word scale)? None looks "done" to me.
2. Font policy for v1: accept whatever the cascade gives (Courier New), pick an explicit Arabic font
   (SF Arabic / Geeza Pro), or revisit bundling a monospace-designed Arabic font (brief section 9.8).
3. Whether the cursor/column cost of model C is acceptable. In C a run is not on a uniform grid, so cursor
   placement and selection edges inside a run must be interpolated.

## Not done / caveats

- Only retina 2x, three sizes, this machine's fonts, one primary Latin font (Menlo).
- Cell width is Menlo's 'M' advance rounded to whole pixels; glyph origins snap to whole pixels.
- No cursor, selection, or typing behaviour yet (Phase 4).

## C fit (built in the spike, 2026-11-13)

Model D in `src/shape/layout.zig`, drawn by `src/spike.zig` into a CGContext (CPU-drawn; no atlas, no Metal).

**How it works.** The grid stays authoritative: cells, logical columns and copy never depend on glyph geometry.
Each maximal run of Arabic characters containing a letter is shaped on its own, justified by CoreText
(`CTLineCreateJustifiedLine`, real kashida) to exactly `cells x cellWidth`, and drawn. A word wider than its cells is scaled down uniformly;
a word CoreText cannot stretch is centred. Per-cluster extents come from `CTLineGetOffsetForStringIndex` on the fitted line, so cursor
and selection follow the letters. Everything outside a word (Latin, digits, spaces, box drawing) stays on whole cells.

**Two things found while building it (both covered by tests, `zig build test`, 8 tests):**
- CoreText's caret offsets collapse inside a ligature: lam-alef gave the lam the whole glyph and the alef zero width.
  The ligature's span is now split equally among the clusters it covers (first logical cluster on the right, words are RTL).
- Justification emits dozens of tiny tatweel glyphs per kashida (about 0.7 px each). Drawing is batched into one
  `CTFontDrawGlyphs` call per run of glyphs with the same font and scale.

**Cursor and selection in the spike (demo only, not the real selection engine):** the fitted panel shows a caret at a logical column (orange)
and the typing position (green), both at the cluster's leading edge, and a visual drag selection that snaps to the nearest cluster boundary.
Copy is the selected clusters in logical order, like a text editor. Examples printed in `docs/cell-model/report.txt` (Geeza Pro 14 pt):
`world` to `مرحبا` copies `حبا rld 123`; `s` to `ل` in `ls ملف.txt` copies `s لف`.

**Observations (implementer's, from the PNGs):**
- Spacing: words now fill their cells, word gaps are the space cells, joins are natural. This fixes the owner's first complaint in Geeza Pro, Al Nile and Courier New.
- **Remaining unevenness:** a word whose letters cannot join forward (ا د ذ ر ز و) or that ends in such a letter cannot take kashida,
  so some air stays, centred or trailing. Visible in `إلا`, `الله`, `اختبار`, `النتيجة`. Worst in SF Arabic (wide letterforms, final ر/ة leave a gap before the next token).
  Possible tweak, not built: centre the *ink* (glyph bounds) in the span instead of trusting the justified advance width.
- Typing panel (`السلام عليكم` one letter at a time): the word is re-fitted on every keystroke. Its first-typed letter moves right as the word grows,
  because a left-origin row grows an RTL word towards the left. That is the section 4.5 effect, not specific to C fit; kashida also moves between keystrokes.
  Whether this is acceptable, or the input line should be right-aligned, is a design call for the owner.
- Tashkeel, lam-alef and Arabic-Indic digits render correctly in the fitted panel; box row bars stay in place.

**Al Nile copy differences in `report.txt` (14 pt: `با` instead of `حبا`, `s ف` instead of `s لف`):** explained by reading the demo, not a core bug.
The demo drag ends at the *centre* of the endpoint cluster and snaps it to the nearest cluster edge. A centre is equidistant from its own two
edges, so the winner is decided by float rounding and edge order; in both cases the dropped letter is exactly the endpoint cluster. A real
pointer position has no such tie. No change made.

**Not done:** the real selection/cursor engine (Phase 4/7), mouse hit-testing, pasteboard, ink centring, a decision on typing alignment,
and any measurement of redraw cost per dirty RTL row.
