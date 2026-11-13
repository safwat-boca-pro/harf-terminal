//! C ABI surface. Keep in sync with include/harf.h.

/// Phase 0 smoke test. Returns 0x48415246 ("HARF").
export fn harf_ping() u32 {
    return 0x48415246;
}

test "harf_ping returns magic" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0x48415246), harf_ping());
}
