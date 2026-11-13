/* Harf core C ABI. Hand-written; keep in sync with src/capi.zig. */
#ifndef HARF_H
#define HARF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Phase 0 smoke test: returns a fixed magic value so the shell can prove the
 * Zig core is linked and callable. */
uint32_t harf_ping(void);

#ifdef __cplusplus
}
#endif

#endif /* HARF_H */
