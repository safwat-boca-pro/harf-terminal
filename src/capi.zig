//! C ABI surface. Keep in sync with include/harf.h.
const std = @import("std");
const ct = @import("shape/ct.zig");
const spike = @import("spike.zig");
const layout = @import("shape/layout.zig");

/// Phase 0 smoke test. Returns 0x48415246 ("HARF").
export fn harf_ping() u32 {
    return 0x48415246;
}

// ---- Phase 1 spike (temporary; replaced by the real draw-rows API in Phase 4) ----

export fn harf_spike_new() ?*spike.Spike {
    return spike.Spike.create(std.heap.smp_allocator) catch null;
}

export fn harf_spike_free(s: *spike.Spike) void {
    s.destroy();
}

export fn harf_spike_metrics(s: *spike.Spike, font_spec: [*:0]const u8, size_px: f32, out: *spike.Metrics) void {
    out.* = s.metrics(std.mem.span(font_spec), size_px);
}

/// Lays out and draws one row into a y-down CGContext.
export fn harf_spike_draw_row(s: *spike.Spike, ctx: *ct.CGContext, req: *const spike.RowRequest, info: *layout.RowInfo) void {
    s.drawRow(ctx, req.*, info);
}

/// Copies the cluster extents of the last drawn row (model 3). Returns how many exist; writes at most `cap`.
export fn harf_spike_extents(s: *spike.Spike, out: [*]layout.Extent, cap: usize) usize {
    const ex = s.extents();
    const n = @min(ex.len, cap);
    @memcpy(out[0..n], ex[0..n]);
    return ex.len;
}

test "harf_ping returns magic" {
    try std.testing.expectEqual(@as(u32, 0x48415246), harf_ping());
}

test {
    _ = @import("shape/layout.zig");
    _ = @import("bidi/bidi.zig");
}
