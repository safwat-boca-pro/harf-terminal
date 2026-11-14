/* Harf core C ABI. Hand-written; keep in sync with src/capi.zig. */
#ifndef HARF_H
#define HARF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Phase 0 smoke test: returns a fixed magic value so the shell can prove the
 * Zig core is linked and callable. */
uint32_t harf_ping(void);

/* ---- Terminal sessions (Phase 3): a child on a PTY, parsed into a logical-order grid ---- */

typedef struct HarfTerm HarfTerm;

/* Callbacks run on the session's I/O thread: keep them short, and do not call back into the
 * session except harf_term_wake_handled. wake fires once, then not again until
 * harf_term_wake_handled is called. */
typedef struct {
    void *ctx;
    void (*wake)(void *ctx);
    void (*title)(void *ctx);
    void (*bell)(void *ctx);
    void (*exited)(void *ctx, int status);
} HarfTermCallbacks;

/* argv: NULL-terminated program and arguments (argv[0] is the path), or NULL for the login shell.
 * Returns NULL for a zero size or if the child cannot start. */
HarfTerm *harf_term_new(uint16_t cols, uint16_t rows, size_t scrollback_bytes,
                        const char *const *argv, const HarfTermCallbacks *cb);
/* Stops the session (hangs up on the child if it still runs). No callback runs after it returns. */
void harf_term_free(HarfTerm *t);
/* Sends bytes to the child as if typed. 0 = ok. */
int harf_term_input(HarfTerm *t, const uint8_t *bytes, size_t len);
/* cell_w_px, cell_h_px: pixel size of one cell. 0 = ok. */
int harf_term_resize(HarfTerm *t, uint16_t cols, uint16_t rows, uint32_t cell_w_px, uint32_t cell_h_px);
/* UTF-8 text of visible row `row`, trailing blanks trimmed, no NUL. Returns bytes written (cut off at cap). */
size_t harf_term_row_text(HarfTerm *t, uint16_t row, char *out, size_t cap);
/* Copies the title the child set (no NUL). Returns bytes written, cut off at cap. */
size_t harf_term_title(HarfTerm *t, char *out, size_t cap);

/* A font at size_px device pixels with its glyph cache. */
typedef struct HarfPainter HarfPainter;
typedef struct {
    float cell_w, cell_h; /* whole-pixel cell size */
    float ascent;         /* baseline offset from the top of a cell */
} HarfCellMetrics;
HarfPainter *harf_painter_new(float size_px);
void harf_painter_free(HarfPainter *p);
void harf_painter_metrics(HarfPainter *p, HarfCellMetrics *out);
/* Draws rows first_row..last_row (inclusive, clamped to the grid) and the cursor into a y-down
 * CGContextRef in device pixels; the grid's top-left is the context's origin. Locks the session. */
void harf_term_draw(HarfTerm *t, HarfPainter *p, void *cg_context, uint16_t first_row, uint16_t last_row);

/* Modifier bits for harf_term_key. */
#define HARF_MOD_SHIFT 1
#define HARF_MOD_CTRL 2
#define HARF_MOD_ALT 4
#define HARF_MOD_SUPER 8
/* keycode: macOS virtual keycode. utf8: the text the layout types for the key with Control removed
 * (Shift applied; may be empty). unshifted: the layout's character for the key with no modifiers, as a
 * Unicode scalar (0 if unknown). A Control combination is named by the layout's letter, so AZERTY,
 * Dvorak and Colemak work, and by the physical US key when the layout has no ASCII letter there.
 * action: 0 press, 1 release, 2 repeat. Returns 1 if handled (function keys, Control combinations,
 * lone modifiers: bytes were queued), 0 if it is a text key to send with harf_term_input or a key
 * with no encoding, -1 on error. */
int harf_term_key(HarfTerm *t, uint16_t keycode, uint32_t mods, const uint8_t *utf8, size_t len, uint32_t unshifted, int action);
/* Wheel or trackpad: delta_rows rows toward newer output when positive, toward older when negative.
 * On the alternate screen the program gets that many Up/Down key presses instead. 0 = ok. */
int harf_term_scroll(HarfTerm *t, int32_t delta_rows);
/* A mouse event at a pixel of the grid (device pixels, origin at its top-left). action: 0 press, 1 release,
 * 2 motion. button: 0 none, 1 left, 2 right, 3 middle. Returns 1 if the program has mouse tracking on and took
 * the event, 0 if the caller keeps it for selection (Shift always keeps it), -1 on error. */
int harf_term_mouse(HarfTerm *t, HarfPainter *p, int action, int button, uint32_t mods, double x_px, double y_px);
/* The window gained (1) or lost (0) focus: the cursor is hollow while unfocused, and a program that enabled
 * focus events (mode 1004) is told. 0 = ok. */
int harf_term_focus(HarfTerm *t, int focused);
/* A left-button selection gesture at a pixel of the grid (use it when harf_term_mouse returned 0).
 * phase: 0 press, 1 drag, 2 release. click_count: 1, 2 (word) or 3 (line). 0 = ok. */
int harf_term_selection_event(HarfTerm *t, HarfPainter *p, int phase, int click_count, uint32_t mods, double x_px, double y_px);
/* The selected text as UTF-8 in logical order, or NULL if nothing is selected; *len is its length. Free with harf_free. */
uint8_t *harf_term_selection_text(HarfTerm *t, size_t *len);
void harf_free(void *p);
void harf_term_clear_selection(HarfTerm *t);
/* The terminal's current default background (a program's OSC 11 changes it) as R, G, B bytes: fill the margins
 * around the grid with it. */
void harf_term_default_bg(HarfTerm *t, uint8_t rgb[3]);
/* The terminal's real grid size (a program can change it, for example to 132 columns, without the view knowing). */
void harf_term_grid(HarfTerm *t, uint16_t *cols, uint16_t *rows);
/* Pastes text, framed for the terminal's paste mode (bracketed, newlines as CR). 0 = ok. */
int harf_term_paste(HarfTerm *t, const uint8_t *utf8, size_t len);
void harf_term_wake_handled(HarfTerm *t);
/* The child's exit code once it has ended and its output is parsed; -1 while it runs. */
int harf_term_exit_status(HarfTerm *t);

#ifdef __cplusplus
}
#endif

#endif /* HARF_H */
