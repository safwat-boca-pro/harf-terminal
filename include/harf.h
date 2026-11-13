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

/* ---- Phase 1 spike (temporary; replaced by the draw-rows API in Phase 4) ---- */

typedef struct HarfSpike HarfSpike;

typedef struct {
    float cell_w, cell_h;
    float ascent;          /* baseline offset from the top of a cell row */
    float arabic_ascent, arabic_descent, arabic_leading;
} HarfMetrics;

/* model: 0 = A snap to cell origin, 1 = B scale to cell, 2 = C natural run,
 *        3 = D "C fitted": each Arabic word justified (kashida) to exactly its cells.
 * base_dir: 0 = auto (first strong), 1 = LTR, 2 = RTL.
 * baseline_y is in the context's coordinates; the CGContext must be y-down. */
typedef struct {
    const uint8_t *utf8;
    size_t len;
    const char *font_spec; /* Arabic font family name, or "system" */
    float size_px;
    uint32_t model;
    uint32_t base_dir;
    float origin_x, baseline_y;
    float color[4];
} HarfRowRequest;

typedef struct {
    uint32_t n_cells;
    uint32_t rtl_base;
    uint32_t foreign_runs;  /* runs shaped with a font other than the requested ones */
    char foreign_name[48];
} HarfRowInfo;

/* Where one cluster (a cell's base letter + marks) is drawn. Model 3 only.
 * x0..x1: visual pixels relative to the row origin. lcol: logical cell column.
 * text_start/text_len: UTF-8 byte range of the cluster in the request text. */
typedef struct {
    uint32_t lcol;
    float x0, x1;
    uint32_t text_start, text_len;
} HarfExtent;

HarfSpike *harf_spike_new(void);
void harf_spike_free(HarfSpike *s);
void harf_spike_metrics(HarfSpike *s, const char *font_spec, float size_px, HarfMetrics *out);
/* ctx is a CGContextRef. */
void harf_spike_draw_row(HarfSpike *s, void *ctx, const HarfRowRequest *req, HarfRowInfo *info);
/* Extents of the last drawn row. Returns the count; writes at most cap. */
size_t harf_spike_extents(HarfSpike *s, HarfExtent *out, size_t cap);

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
void harf_term_wake_handled(HarfTerm *t);
/* The child's exit code once it has ended and its output is parsed; -1 while it runs. */
int harf_term_exit_status(HarfTerm *t);

#ifdef __cplusplus
}
#endif

#endif /* HARF_H */
