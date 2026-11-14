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
    /* OSC 52: UTF-8 text a program put on the clipboard (no NUL, borrowed for the call). Only called when the policy
     * (harf_term_set_clipboard_write) allows it, and only for the standard clipboard. */
    void (*clipboard_write)(void *ctx, const uint8_t *text, size_t len);
    /* OSC 9 / 777: untrusted UTF-8 title (may be empty) and body, borrowed for the call. */
    void (*notify)(void *ctx, const uint8_t *title, size_t title_len, const uint8_t *body, size_t body_len);
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
/* Like harf_painter_new in the font family `family` (UTF-8). NULL if it is not installed or not monospaced. */
HarfPainter *harf_painter_new_font(const char *family, float size_px);
void harf_painter_free(HarfPainter *p);
void harf_painter_metrics(HarfPainter *p, HarfCellMetrics *out);
/* Draws rows first_row..last_row (inclusive, clamped to the grid) and the cursor into a y-down
 * CGContextRef in device pixels; the grid's top-left is the context's origin. Locks the session. */
void harf_term_draw(HarfTerm *t, HarfPainter *p, void *cg_context, uint16_t first_row, uint16_t last_row);
/* Which visible rows differ from what harf_term_draw last drew: out[i] is 1 for a row to redraw (the row above each changed
 * row is included, because glyphs reach into it). Returns the grid's row count; cap is the size of out, and a count larger
 * than cap means the caller must redraw everything. Every row is reported before the first draw and after a change of the
 * grid size or the default colors. harf_term_draw also draws the row below last_row (its glyphs reach up into last_row), but
 * does not count it as drawn, so the context must be clipped to the rows' rectangle. */
size_t harf_term_dirty_rows(HarfTerm *t, HarfPainter *p, uint8_t *out, size_t cap);

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
/* The OSC 8 hyperlink under a pixel of the grid: copies its URI (no NUL) into out and returns its length, or 0 if there is
 * none or it does not fit cap. */
size_t harf_term_hyperlink_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint8_t *out, size_t cap);
/* Clear screen and scrollback, then type Ctrl+L so a shell redraws its prompt; nothing happens on the alternate screen. */
void harf_term_clear(HarfTerm *t);
/* Whether a program may write the clipboard with OSC 52 (1 yes, 0 no; the default is yes). Reading is never allowed. */
void harf_term_set_clipboard_write(HarfTerm *t, int allow);
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

/* A theme's colors for one session. palette_set has bit i set when ANSI color i is given; the others stay the terminal's. */
typedef struct {
    uint8_t fg[3], bg[3];
    uint8_t has_cursor;
    uint8_t cursor[3];
    uint16_t palette_set;
    uint8_t palette[16][3];
} HarfTheme;
/* Applies a theme to this session (default colors, cursor color, ANSI colors) and redraws. 0 = ok. */
int harf_term_set_theme(HarfTerm *t, const HarfTheme *theme);
/* The system appearance, dark (1) or light (0): answers CSI ? 996 n, and tells a program that enabled mode 2031 of a change. */
void harf_term_set_scheme(HarfTerm *t, int dark);

/* ---- Configuration (Phase 6): a `key = value` file, themes and key bindings; the shell applies them ---- */

typedef struct HarfConfig HarfConfig;
/* Reads the configuration in `dir`, or in the default place ($XDG_CONFIG_HOME/harf, else ~/.config/harf) when dir is NULL. A
 * missing directory or file is an empty configuration; bad lines are warnings. Free with harf_config_free. */
HarfConfig *harf_config_load(const char *dir);
void harf_config_free(HarfConfig *cfg);
/* The directory it was read from (valid until harf_config_free). */
const char *harf_config_dir(HarfConfig *cfg);
/* The text of a commented configuration file with every setting at its default (static). */
const char *harf_config_template(void);
const char *harf_config_font_family(HarfConfig *cfg);
float harf_config_font_size(HarfConfig *cfg); /* points */
size_t harf_config_scrollback_bytes(HarfConfig *cfg);
int harf_config_clipboard_write(HarfConfig *cfg); /* 1 allow, 0 deny */
int harf_config_notifications(HarfConfig *cfg);   /* 0 unfocused, 1 always, 2 off */
/* The theme for a dark (1) or light (0) system appearance. */
void harf_config_theme(HarfConfig *cfg, int dark, HarfTheme *out);
/* One key binding: mods use HARF_MOD_*; key is a lowercase character or a name (left, return, f5); action is its name
 * (new_tab, goto_tab, send, ...); arg is the tab number as text for goto_tab, the bytes for send. */
typedef struct {
    uint8_t mods, arg_len;
    char key[16];
    char action[24];
    uint8_t arg[64];
} HarfKeybind;
size_t harf_config_keybind_count(HarfConfig *cfg);
int harf_config_keybind(HarfConfig *cfg, size_t i, HarfKeybind *out); /* 0, or -1 if there is no binding i */
size_t harf_config_warning_count(HarfConfig *cfg);
const char *harf_config_warning(HarfConfig *cfg, size_t i); /* NULL if there is no warning i */

#ifdef __cplusplus
}
#endif

#endif /* HARF_H */
