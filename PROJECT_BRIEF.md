# Project Brief: Arabic-first, Agent-friendly Terminal Emulator for macOS

> Handoff document for Claude Code. Read this fully before writing code.
> Status: pre-implementation. Nothing is built yet. Working name: **TBD** (placeholder `<name>` below).

---

## 1. Goal

Build a **terminal emulator** (not a TUI app that runs inside one) for **macOS on Apple Silicon** that is:

1. **Snappy and light**: low memory and CPU footprint, near-zero idle cost.
2. **Arabic-correct from day 1**: RTL, contextual shaping, and correct mixed Arabic/English (bidi) rendering, with cursor and selection that behave correctly.
3. **Pleasant for developers**, especially those running AI coding agents (Claude Code, Codex) in it.
4. **Open source** (default license: MIT; easy to change, decide before first public commit).

Why an emulator: only an emulator owns the renderer, so only an emulator can fix Arabic shaping and bidi. A TUI app just emits text and the host terminal decides how it looks.

---

## 2. Locked decisions

| Area | Decision |
|---|---|
| Product | Terminal emulator, macOS Apple Silicon only (v1) |
| Core language | **Zig** (pin an exact compiler version, see §10) |
| macOS shell | **Thin Swift/AppKit shell** (the way Ghostty is structured); Zig core exposes a small C ABI |
| Rendering | Metal, glyph atlas, damage tracking, no web view |
| Shaping and font fallback | **CoreText** (system fallback for Arabic; no bundled font in v1) |
| Bidi | Own UAX #9 implementation in Zig, validated against Unicode conformance files |
| Grid model | Grid stays in **logical order**; reordering happens at display time |
| Arabic | Must work from the first usable build, including mixed English/Arabic lines |
| License | Open source; avoid GPL/LGPL dependencies (FriBidi is LGPL, so not used) |
| Performance budgets | See §7 (defaults accepted, with one caveat on RSS) |

---

## 3. Architecture

```
PTY (child shell)
  -> VT parser (escape sequence state machine)
    -> Screen / grid (logical order, damage-tracked)
      -> Per-row layout:  bidi (UAX #9) -> shaping (CoreText) -> cluster-to-cell map
        -> Glyph atlas (rasterize via CoreText, cache)
          -> Frame snapshot (cell instances + atlas updates) over C ABI
            -> Swift/AppKit shell: Metal draw, window, tabs, menus, IME, notifications
```

### 3.1 Zig / Swift split

- **Zig core** owns: PTY, parser, screen/scrollback, layout (bidi + shaping), glyph rasterization and atlas, selection/cursor logic, config.
- **Swift shell** owns: windows, tabs/splits UI, menus, input events and IME (`NSTextInputClient`), Metal pipeline and presentation, notifications, session restore.
- **C ABI** is small and stable: create/destroy terminal, write input, resize, get frame snapshot, get atlas updates, get selection text, callbacks for title/bell/notification/clipboard.
- CoreText has a C API, so Zig calls it directly. Metal is Obj-C/Swift only, so Swift draws.
- Zig builds a static library plus a generated C header; the Swift package/Xcode project links it.

### 3.2 Threads

- I/O thread: PTY read, parse, mutate screen.
- Render side: takes a consistent snapshot (lock or double buffer), draws only damaged rows.
- No timers while idle. Cursor blink and animations only run while needed.

### 3.3 Fast path

Rows containing **no RTL code points** skip bidi and shaping entirely and take the plain-terminal path. Only rows with Arabic (or other RTL) pay the layout cost. Shaped rows are cached until they become dirty. Ordinary output must run at plain-terminal speed.

---

## 4. Arabic and bidi design

### 4.1 Requirements

- Contextual shaping (initial/medial/final/isolated forms), lam-alef ligature, tashkeel (combining marks) attached to the right base letter.
- Correct bidi for mixed lines: Arabic next to English, numbers, paths, punctuation, brackets (bracket mirroring and pairing per UAX #9).
- Isolates (LRI, RLI, FSI, PDI) and explicit embeddings/overrides handled per UAX #9.
- Arabic-Indic digits (`١٢٣`) and Western digits (`123`) both render correctly.
- Pre-shaped presentation-form code points (U+FB50 to U+FDFF, U+FE70 to U+FEFF) emitted by some apps are treated as ordinary characters.
- Grapheme clusters per UAX #29; cell widths per Unicode width data (Arabic letters are 1 cell; combining marks 0).

### 4.2 Logical grid, visual layout

Apps (shells, vim, tmux) write text in logical order at logical columns. The grid keeps that. At layout time each row gets a **logical to visual map** (and the inverse). Cursor drawing, selection rectangles, mouse hit-testing and copy all go through this map. Copy always produces logical-order text.

### 4.3 Cell model: the main technical risk

Terminals assume one fixed-width cell per cluster; Arabic joins and font advances do not. The spike (Phase 1) must compare at least:

- **A. Shape the whole run, then snap each cluster to its cell origin.** Grid-perfect, but joins can show gaps or overlaps if glyph advance differs from cell width.
- **B. Same as A, with per-glyph horizontal scaling/positioning to close joins.**
- **C. Shape with natural advances and snap only at run boundaries.** Best looking, but column math is harder.

Test with 3 to 4 system fonts. Decision criteria: join continuity, tashkeel placement, lam-alef, legibility at small sizes, cost per row. Document the winner and why in `docs/cell-model.md`.

### 4.4 Base direction policy (needs real design work)

Starting proposal (to be validated, not locked):

- Shell prompt and plain output: per-row base direction from first strong character (auto), with a config override (LTR / RTL / auto).
- Full-screen TUIs and layout-heavy output must **not mirror** boxes and padded layouts. A row like `│ مرحبا    │` reordered with an RTL base would jump text to the right edge and break the layout.

**Important correction to an earlier assumption:** Claude Code and Codex generally render **inline on the primary screen** using cursor positioning and box drawing, not on the alternate screen. So "alt screen means LTR" is not enough. Ideas to evaluate:

- Rows that contain box-drawing characters or were written with absolute cursor positioning get an LTR base (Arabic runs still reordered internally).
- Per-tab toggle plus per-app profile.
- Honor explicit sequences from the Terminal Working Group bidi spec (ECMA-48 BDSM/SPD and related private modes) if apps start emitting them. Read the spec and decide what to implement.
- Use OSC 133 to distinguish prompt/input regions from command output and apply different policies.

### 4.5 Cursor and typing

zsh and readline know nothing about bidi; they move the cursor in logical columns. In a line with an LTR base, an RTL run **grows and shifts as you type** (the first typed character moves as the run extends). This is expected behavior in implicit-mode bidi terminals, but it must feel acceptable. Phase 4 should prototype options, for example treating the OSC 133 input region as its own paragraph with direction chosen by first strong character. Study existing behavior before inventing.

### 4.6 Conformance

- Implement UAX #9 in Zig and run **BidiTest.txt** and **BidiCharacterTest.txt** from unicode.org in CI. Download them in a build/test step with a pinned Unicode version, or vendor them if the license allows.
- Add golden tests for layout: input string -> visual order + logical/visual maps.

### 4.7 Sample strings for tests

```
مرحبا world 123
السلام عليكم ورحمة الله
مُحَمَّد                       (tashkeel)
لا إله إلا الله               (lam-alef)
ls ملف.txt                     (path with Arabic)
"النتيجة: ١٢٣ (ناجح)"          (Arabic-Indic digits + brackets)
echo "اختبار" | wc -c          (shell line)
│ مرحبا    │                   (box layout, must not mirror)
```

The product owner is an Arabic speaker and will judge visual quality. Prefer asking for screenshots/feedback over assuming a rendering is correct.

---

## 5. Agent-compatibility (v1, non-negotiable)

Claude Code and Codex stress terminals with streaming redraws, boxes, and rich input. v1 must support:

- **Synchronized output** (DEC private mode 2026): no flicker on redraw.
- **Damage tracking**: a token stream repaints a few rows, not the whole screen.
- **Bracketed paste**, **focus events**, **truecolor**, mouse reporting (SGR).
- **Kitty keyboard protocol** (so Shift+Enter inserts a newline, plus modifiers in general).
- **OSC 8** hyperlinks, **OSC 52** clipboard (with a permission setting), **OSC 9 / OSC 777** notifications.
- Common terminal queries and replies (DA1/DA2, DSR/cursor position report, OSC 10/11 color queries for theme detection, XTVERSION). Verify against what Claude Code and Codex actually send.
- Underline styles/colors, cursor shape (DECSCUSR), wide characters and emoji widths.
- Correct **alternate screen** and **scrollback** behavior, plus resize reflow that does not corrupt inline UIs.

Test matrix: shell, vim/neovim, tmux, htop, less, fzf, **Claude Code**, **Codex CLI**, plus `vttest` and an escape-sequence conformance suite.

---

## 6. Developer UX

### v1

- **OSC 133 shell integration**: jump between prompts, select/copy last command output, mark failed commands.
- **Per-tab status**: running / idle / waiting for input, with a notification when a background agent finishes or asks for approval.
- **Cmd-click on `path:line:col`** opens in the user's editor (configurable command).
- **Tabs and splits** for parallel agent sessions, fast session restore.
- **Scrollback search** that is bidi-aware (search in logical text, highlight in visual positions).
- **Large-paste guard** (confirm before pasting very large or multi-line content).
- Sensible defaults, plain-text config file, hot reload of config and themes, light/dark themes.

### v2 (parked, needs a permission model)

- Local control socket + CLI so an agent can read a pane, send keys, create panes. Powerful but security-sensitive: design permissions first.

---

## 7. Performance budgets

| Metric | Target |
|---|---|
| Idle CPU | ~0% (no timers, no redraw when idle) |
| Keypress to pixel | under 10 ms |
| Startup | under 100 ms to first usable frame |
| Idle RSS | under 30 MB (see caveat) |
| Throughput | competitive with other GPU terminals on vtebench-style workloads |
| Scrollback | configurable; compact row storage; default sized to the memory budget |

**Caveat on RSS:** AppKit + Metal themselves may exceed 30 MB. In Phase 0, measure an empty AppKit + Metal window first, then confirm or revise the target relative to that baseline and record it in `docs/perf.md`.

**Method:** set up benchmarks **before** optimizing. Use vtebench for throughput, Instruments (Time Profiler, Allocations, Metal System Trace) for CPU/memory/GPU, and an internal keypress-to-present timestamp for latency. Track results in `docs/perf.md` with machine and OS version.

---

## 8. Roadmap and acceptance criteria

**Phase 0: Scaffolding and baselines**
- Pinned Zig, `build.zig` producing a static lib + C header, Swift app shell that links it, CI, license, `ARCHITECTURE.md`.
- Measure empty AppKit + Metal window RSS/CPU.
- Done when: app opens a blank Metal window and calls one function in the Zig core.

**Phase 1: Arabic render spike**
- Metal window, glyph atlas, CoreText shaping + fallback, hardcoded mixed lines, compare cell models (§4.3) across 3 to 4 fonts.
- Done when: the owner confirms the sample strings in §4.7 look right and the cell model decision is documented.

**Phase 2: Bidi (UAX #9)**
- Full algorithm incl. isolates, brackets, numbers.
- Done when: BidiTest.txt and BidiCharacterTest.txt pass in CI.

**Phase 3: PTY + parser + grid (LTR only)**
- Run zsh; pass core `vttest` cases; vim, tmux, htop, less work.
- Decide: write own parser vs. evaluate reusing Ghostty's Zig terminal library (see §9).
- Done when: daily-usable plain terminal, benchmarks recorded.

**Phase 4: Layout integrated with the grid**
- Per-row layout, logical/visual maps, cursor placement, base-direction policy (§4.4), typing behavior (§4.5).
- Done when: Arabic typed at a zsh prompt and Arabic command output look correct; boxes do not mirror.

**Phase 5: Agent compatibility (§5)**
- Done when: Claude Code and Codex run without flicker or layout bugs, including with Arabic content.

**Phase 6: Developer UX (§6, v1 list)**

**Phase 7: Selection, copy/paste, IME and Arabic keyboard input, polish, benchmarks against §7**

---

## 9. Open questions and things to verify

Do not rely on these without checking:

1. **Parser reuse in Zig.** Earlier discussion mentioned Rust crates (`vte`, `alacritty_terminal`), which do not apply to a Zig core. Options: write a VT parser (Paul Williams' state machine) or evaluate Ghostty's Zig terminal library (`libghostty-vt`). Check its current status, API stability and license. Ghostty has no bidi layer as far as known, so bidi would be added on top. Verify.
2. **Prior art for bidi in terminals.** Study VTE (GNOME Terminal), mlterm, Konsole, WezTerm, iTerm2, and the Terminal Working Group bidi spec. Verify what each currently supports.
3. **Cell model** winner (§4.3) and whether Arabic glyphs look acceptable when snapped.
4. **Base direction policy** for inline agent UIs (§4.4).
5. **Typing behavior** at prompts (§4.5).
6. **Who rasterizes glyphs**: proposed in Zig via CoreText into atlas bitmaps that Swift uploads. Confirm it is clean across the C ABI.
7. **Name, final license, minimum macOS version.**
8. **Fonts**: v1 relies on system fallback. Revisit bundling a monospace font with good Arabic coverage only if fallback quality is poor.
9. **Hosting/distribution**: notarization, signing, auto-update (later).

---

## 10. Proposed repo layout

```
<name>/
  build.zig
  build.zig.zon
  .zig-version            # pinned compiler
  LICENSE
  ARCHITECTURE.md
  include/<name>.h        # C ABI header (generated or hand-written, kept in sync)
  src/
    pty.zig
    parser.zig
    screen.zig            # grid, scrollback, damage tracking
    bidi/                 # UAX #9 + tables + conformance tests
    shape/                # CoreText bindings, cluster-to-cell map
    atlas.zig
    capi.zig
    config.zig
  macos/                  # Swift package / Xcode project (thin shell)
  bench/                  # vtebench configs, latency harness
  test/                   # golden layout tests, escape sequence tests
  docs/
    cell-model.md
    perf.md
    bidi-policy.md
```

---

## 11. Working agreements for Claude Code

1. **Read this brief first.** Do not change a locked decision (§2) without asking.
2. **Zig moves fast.** Run `zig version`, pin it, and read the stdlib source for the pinned version instead of recalling APIs from memory. Do not guess function signatures.
3. **Verify before relying** on anything in §9.
4. **Test first for bidi.** Conformance files in CI before wiring layout into the grid.
5. **Measure before optimizing.** Record benchmark results in `docs/perf.md`.
6. **Dependencies:** none without discussion; license must be MIT-compatible (no GPL/LGPL).
7. **Small commits per phase**, each meeting its acceptance criteria. Stop and ask when a design question in §4.4 or §4.5 needs a human judgment about how Arabic should look or feel.
8. **Use real Arabic test strings** (§4.7) and ask the owner for screenshots/feedback on visual correctness.
9. Keep the C ABI small. Prefer adding capability in Zig over adding Swift logic.
10. Keep idle cost at zero: no polling, no always-on timers.

---

## 12. First prompt to paste into Claude Code

```
Read PROJECT_BRIEF.md in full. Then do Phase 0 only:
1. Run `zig version`, pin the compiler in .zig-version and build.zig.zon.
2. Scaffold the repo layout from section 10 (empty modules are fine).
3. Make build.zig produce a static library and a C header exposing one test function.
4. Create a minimal Swift/AppKit app under macos/ that links the library, opens a Metal-backed window, and calls the test function.
5. Measure RSS and idle CPU of the empty app and write the numbers to docs/perf.md.
6. Write ARCHITECTURE.md summarizing section 3.
Do not start Phase 1. Ask me about the project name and license before the first commit.
```
