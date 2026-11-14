//! Hand-written CoreText / CoreGraphics / CoreFoundation bindings (only what Harf uses).
//! Signatures and constant values were checked against the macOS SDK headers
//! (CoreText, CoreGraphics, CoreFoundation) and a C probe that printed the enums.

pub const CFIndex = isize;
pub const CGFloat = f64;
pub const CGGlyph = u16;
pub const UniChar = u16;

pub const CFString = opaque {};
pub const CFAttrString = opaque {};
pub const CFArray = opaque {};
pub const CFDictionary = opaque {};
pub const CTFont = opaque {};
pub const CTLine = opaque {};
pub const CTRun = opaque {};
pub const CTParagraphStyle = opaque {};
pub const CGContext = opaque {};

pub const CFRange = extern struct { location: CFIndex, length: CFIndex };
pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
pub const CGSize = extern struct { width: CGFloat, height: CGFloat };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };
/// CTParagraphStyleSetting: 24 bytes (verified with sizeof).
pub const ParagraphSetting = extern struct { spec: u32, value_size: usize, value: *const anyopaque };

pub const encoding_utf8: u32 = 0x08000100; // kCFStringEncodingUTF8
pub const spec_base_writing_direction: u32 = 13; // kCTParagraphStyleSpecifierBaseWritingDirection
pub const dir_ltr: i8 = 0; // kCTWritingDirectionLeftToRight (CTWritingDirection is 1 byte)
pub const dir_rtl: i8 = 1; // kCTWritingDirectionRightToLeft
pub const orientation_horizontal: u32 = 1; // kCTFontOrientationHorizontal
pub const run_status_rtl: u32 = 1; // kCTRunStatusRightToLeft
pub const ui_font_system: u32 = 2; // kCTFontUIFontSystem
pub const alpha_only: u32 = 7; // kCGImageAlphaOnly

/// New CFString from UTF-8 bytes; caller releases with CFRelease.
pub fn cfString(s: []const u8) ?*const CFString {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), encoding_utf8, false);
}

// CoreFoundation (NULL allocator means the default allocator)
pub extern fn CFRetain(cf: *const anyopaque) *const anyopaque;
pub extern fn CFRelease(cf: *const anyopaque) void;
pub extern fn CFEqual(a: *const anyopaque, b: *const anyopaque) bool;
pub extern fn CFStringCreateWithBytes(alloc: ?*const anyopaque, bytes: [*]const u8, num_bytes: CFIndex, encoding: u32, is_external: bool) ?*const CFString;
pub extern fn CFStringGetCString(s: *const CFString, buffer: [*]u8, buffer_size: CFIndex, encoding: u32) bool;
pub extern fn CFAttributedStringCreateMutable(alloc: ?*const anyopaque, max_length: CFIndex) ?*CFAttrString;
pub extern fn CFAttributedStringReplaceString(s: *CFAttrString, range: CFRange, replacement: *const CFString) void;
pub extern fn CFAttributedStringSetAttribute(s: *CFAttrString, range: CFRange, name: *const CFString, value: *const anyopaque) void;
pub extern fn CFArrayGetCount(a: *const CFArray) CFIndex;
pub extern fn CFArrayGetValueAtIndex(a: *const CFArray, idx: CFIndex) *const anyopaque;
pub extern fn CFDictionaryGetValue(d: *const CFDictionary, key: *const anyopaque) ?*const anyopaque;

// CoreText
pub extern const kCTFontAttributeName: *const CFString;
pub extern const kCTParagraphStyleAttributeName: *const CFString;
pub extern fn CTFontCreateWithName(name: *const CFString, size: CGFloat, matrix: ?*const anyopaque) ?*CTFont;
pub extern fn CTFontCreateUIFontForLanguage(ui_type: u32, size: CGFloat, language: ?*const CFString) ?*CTFont;
pub const trait_italic: u32 = 1 << 0; // kCTFontTraitItalic
pub const trait_bold: u32 = 1 << 1; // kCTFontTraitBold
pub const trait_monospace: u32 = 1 << 10; // kCTFontTraitMonoSpace
pub extern fn CTFontGetSymbolicTraits(font: *const CTFont) u32;
pub extern fn CTFontCreateCopyWithSymbolicTraits(font: *const CTFont, size: CGFloat, matrix: ?*const anyopaque, value: u32, mask: u32) ?*CTFont;
pub extern fn CTFontCreateForString(current: *const CTFont, string: *const CFString, range: CFRange) ?*CTFont;
pub extern fn CTFontCopyFullName(font: *const CTFont) ?*const CFString;
pub extern fn CTFontGetGlyphsForCharacters(font: *const CTFont, chars: [*]const UniChar, glyphs: [*]CGGlyph, count: CFIndex) bool;
pub extern fn CTFontGetAdvancesForGlyphs(font: *const CTFont, orientation: u32, glyphs: [*]const CGGlyph, advances: ?[*]CGSize, count: CFIndex) f64;
pub extern fn CTFontGetBoundingRectsForGlyphs(font: *const CTFont, orientation: u32, glyphs: [*]const CGGlyph, rects: ?[*]CGRect, count: CFIndex) CGRect;
pub extern fn CTFontGetAscent(font: *const CTFont) CGFloat;
pub extern fn CTFontGetDescent(font: *const CTFont) CGFloat;
pub extern fn CTFontGetLeading(font: *const CTFont) CGFloat;
pub extern fn CTFontDrawGlyphs(font: *const CTFont, glyphs: [*]const CGGlyph, positions: [*]const CGPoint, count: usize, ctx: *CGContext) void;
pub extern fn CTLineCreateWithAttributedString(s: *const CFAttrString) ?*CTLine;
pub extern fn CTLineGetGlyphRuns(line: *const CTLine) *const CFArray;
pub extern fn CTLineCreateJustifiedLine(line: *const CTLine, factor: CGFloat, width: f64) ?*CTLine;
pub extern fn CTLineGetOffsetForStringIndex(line: *const CTLine, index: CFIndex, secondary: ?*CGFloat) CGFloat;
pub extern fn CTLineGetTypographicBounds(line: *const CTLine, ascent: ?*CGFloat, descent: ?*CGFloat, leading: ?*CGFloat) f64;
pub extern fn CTRunGetGlyphCount(run: *const CTRun) CFIndex;
pub extern fn CTRunGetGlyphs(run: *const CTRun, range: CFRange, buffer: [*]CGGlyph) void;
pub extern fn CTRunGetPositions(run: *const CTRun, range: CFRange, buffer: [*]CGPoint) void;
pub extern fn CTRunGetAdvances(run: *const CTRun, range: CFRange, buffer: [*]CGSize) void;
pub extern fn CTRunGetStringIndices(run: *const CTRun, range: CFRange, buffer: [*]CFIndex) void;
pub extern fn CTRunGetAttributes(run: *const CTRun) *const CFDictionary;
pub extern fn CTRunGetStatus(run: *const CTRun) u32;
pub extern fn CTRunGetStringRange(run: *const CTRun) CFRange;
pub extern fn CTParagraphStyleCreate(settings: [*]const ParagraphSetting, count: usize) ?*CTParagraphStyle;

// CoreGraphics
pub extern fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: ?*const anyopaque, bitmap_info: u32) ?*CGContext;
pub extern fn CGContextRelease(ctx: *CGContext) void;
pub extern fn CGContextSaveGState(ctx: *CGContext) void;
pub extern fn CGContextRestoreGState(ctx: *CGContext) void;
pub extern fn CGContextTranslateCTM(ctx: *CGContext, tx: CGFloat, ty: CGFloat) void;
pub extern fn CGContextSetRGBFillColor(ctx: *CGContext, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern fn CGContextFillRect(ctx: *CGContext, rect: CGRect) void;
pub extern fn CGContextSetShouldAntialias(ctx: *CGContext, should: bool) void;
pub extern fn CGContextSetShouldSmoothFonts(ctx: *CGContext, should: bool) void;
pub extern fn CGContextSetGrayFillColor(ctx: *CGContext, gray: CGFloat, alpha: CGFloat) void;
pub extern fn CGContextScaleCTM(ctx: *CGContext, sx: CGFloat, sy: CGFloat) void;
pub extern fn CGColorSpaceCreateDeviceRGB() ?*const anyopaque;
pub extern fn CGColorSpaceRelease(space: *const anyopaque) void;
pub extern fn CGContextSetRGBStrokeColor(ctx: *CGContext, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern fn CGContextSetLineWidth(ctx: *CGContext, w: CGFloat) void;
pub extern fn CGContextBeginPath(ctx: *CGContext) void;
pub extern fn CGContextMoveToPoint(ctx: *CGContext, x: CGFloat, y: CGFloat) void;
pub extern fn CGContextAddLineToPoint(ctx: *CGContext, x: CGFloat, y: CGFloat) void;
pub extern fn CGContextStrokePath(ctx: *CGContext) void;
pub extern fn CGContextClipToRect(ctx: *CGContext, rect: CGRect) void;
