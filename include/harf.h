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
/* Pastes text, framed for the terminal's paste mode (bracketed, newlines as CR). 0 = ok. */
int harf_term_paste(HarfTerm *t, const uint8_t *utf8, size_t len);
void harf_term_wake_handled(HarfTerm *t);
/* The child's exit code once it has ended and its output is parsed; -1 while it runs. */
int harf_term_exit_status(HarfTerm *t);

#ifdef __cplusplus
}
#endif

#endif /* HARF_H */
