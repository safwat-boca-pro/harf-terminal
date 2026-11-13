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

#ifdef __cplusplus
}
#endif

#endif /* HARF_H */
