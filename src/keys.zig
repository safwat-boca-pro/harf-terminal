//! macOS virtual keycodes (what `NSEvent.keyCode` reports) to libghostty's physical key codes.
//! The table is here, not in Swift, so it is tested and the shell stays thin.
const std = @import("std");
const c = @import("vt.zig").c;

/// Modifier bits of `harf_term_key`'s `mods`. They are the same bits as libghostty's.
pub const Mods = struct {
    pub const shift: u32 = 1;
    pub const ctrl: u32 = 2;
    pub const alt: u32 = 4;
    pub const super: u32 = 8;
};

/// Keycodes of the modifier keys themselves (command, shift, caps lock, option, control, fn).
pub fn isModifierKeycode(code: u16) bool {
    return switch (code) {
        54...63 => true,
        else => false,
    };
}

pub fn fromMac(code: u16) ?c.GhosttyKey {
    return switch (code) {
        // letters
        0 => c.GHOSTTY_KEY_A,
        1 => c.GHOSTTY_KEY_S,
        2 => c.GHOSTTY_KEY_D,
        3 => c.GHOSTTY_KEY_F,
        4 => c.GHOSTTY_KEY_H,
        5 => c.GHOSTTY_KEY_G,
        6 => c.GHOSTTY_KEY_Z,
        7 => c.GHOSTTY_KEY_X,
        8 => c.GHOSTTY_KEY_C,
        9 => c.GHOSTTY_KEY_V,
        11 => c.GHOSTTY_KEY_B,
        12 => c.GHOSTTY_KEY_Q,
        13 => c.GHOSTTY_KEY_W,
        14 => c.GHOSTTY_KEY_E,
        15 => c.GHOSTTY_KEY_R,
        16 => c.GHOSTTY_KEY_Y,
        17 => c.GHOSTTY_KEY_T,
        31 => c.GHOSTTY_KEY_O,
        32 => c.GHOSTTY_KEY_U,
        34 => c.GHOSTTY_KEY_I,
        35 => c.GHOSTTY_KEY_P,
        37 => c.GHOSTTY_KEY_L,
        38 => c.GHOSTTY_KEY_J,
        40 => c.GHOSTTY_KEY_K,
        45 => c.GHOSTTY_KEY_N,
        46 => c.GHOSTTY_KEY_M,
        // digits
        18 => c.GHOSTTY_KEY_DIGIT_1,
        19 => c.GHOSTTY_KEY_DIGIT_2,
        20 => c.GHOSTTY_KEY_DIGIT_3,
        21 => c.GHOSTTY_KEY_DIGIT_4,
        22 => c.GHOSTTY_KEY_DIGIT_6,
        23 => c.GHOSTTY_KEY_DIGIT_5,
        25 => c.GHOSTTY_KEY_DIGIT_9,
        26 => c.GHOSTTY_KEY_DIGIT_7,
        28 => c.GHOSTTY_KEY_DIGIT_8,
        29 => c.GHOSTTY_KEY_DIGIT_0,
        // punctuation
        24 => c.GHOSTTY_KEY_EQUAL,
        27 => c.GHOSTTY_KEY_MINUS,
        30 => c.GHOSTTY_KEY_BRACKET_RIGHT,
        33 => c.GHOSTTY_KEY_BRACKET_LEFT,
        39 => c.GHOSTTY_KEY_QUOTE,
        41 => c.GHOSTTY_KEY_SEMICOLON,
        42 => c.GHOSTTY_KEY_BACKSLASH,
        43 => c.GHOSTTY_KEY_COMMA,
        44 => c.GHOSTTY_KEY_SLASH,
        47 => c.GHOSTTY_KEY_PERIOD,
        50 => c.GHOSTTY_KEY_BACKQUOTE,
        // editing and navigation
        36 => c.GHOSTTY_KEY_ENTER,
        48 => c.GHOSTTY_KEY_TAB,
        49 => c.GHOSTTY_KEY_SPACE,
        51 => c.GHOSTTY_KEY_BACKSPACE,
        53 => c.GHOSTTY_KEY_ESCAPE,
        117 => c.GHOSTTY_KEY_DELETE,
        115 => c.GHOSTTY_KEY_HOME,
        119 => c.GHOSTTY_KEY_END,
        116 => c.GHOSTTY_KEY_PAGE_UP,
        121 => c.GHOSTTY_KEY_PAGE_DOWN,
        123 => c.GHOSTTY_KEY_ARROW_LEFT,
        124 => c.GHOSTTY_KEY_ARROW_RIGHT,
        125 => c.GHOSTTY_KEY_ARROW_DOWN,
        126 => c.GHOSTTY_KEY_ARROW_UP,
        // function keys
        122 => c.GHOSTTY_KEY_F1,
        120 => c.GHOSTTY_KEY_F2,
        99 => c.GHOSTTY_KEY_F3,
        118 => c.GHOSTTY_KEY_F4,
        96 => c.GHOSTTY_KEY_F5,
        97 => c.GHOSTTY_KEY_F6,
        98 => c.GHOSTTY_KEY_F7,
        100 => c.GHOSTTY_KEY_F8,
        101 => c.GHOSTTY_KEY_F9,
        109 => c.GHOSTTY_KEY_F10,
        103 => c.GHOSTTY_KEY_F11,
        111 => c.GHOSTTY_KEY_F12,
        else => null,
    };
}

/// Keys that produce no text of their own: the terminal must encode them. Text keys
/// (letters, digits, punctuation, space) go through the text path unless Control is held.
pub fn isFunctional(key: c.GhosttyKey) bool {
    return switch (key) {
        c.GHOSTTY_KEY_A...c.GHOSTTY_KEY_Z, c.GHOSTTY_KEY_DIGIT_0...c.GHOSTTY_KEY_DIGIT_9 => false,
        c.GHOSTTY_KEY_BACKQUOTE, c.GHOSTTY_KEY_BACKSLASH, c.GHOSTTY_KEY_BRACKET_LEFT, c.GHOSTTY_KEY_BRACKET_RIGHT => false,
        c.GHOSTTY_KEY_COMMA, c.GHOSTTY_KEY_EQUAL, c.GHOSTTY_KEY_MINUS, c.GHOSTTY_KEY_PERIOD => false,
        c.GHOSTTY_KEY_QUOTE, c.GHOSTTY_KEY_SEMICOLON, c.GHOSTTY_KEY_SLASH, c.GHOSTTY_KEY_SPACE => false,
        else => true,
    };
}

test "known and unknown keycodes" {
    try std.testing.expectEqual(@as(?c.GhosttyKey, c.GHOSTTY_KEY_ARROW_UP), fromMac(126));
    try std.testing.expectEqual(@as(?c.GhosttyKey, c.GHOSTTY_KEY_ENTER), fromMac(36));
    try std.testing.expectEqual(@as(?c.GhosttyKey, c.GHOSTTY_KEY_C), fromMac(8));
    for ([_]u16{ 55, 56, 59 }) |m| {
        try std.testing.expect(fromMac(m) == null);
        try std.testing.expect(isModifierKeycode(m));
    }
    try std.testing.expect(fromMac(200) == null);
}

test "letters are text keys, arrows are functional" {
    try std.testing.expect(!isFunctional(c.GHOSTTY_KEY_A));
    try std.testing.expect(!isFunctional(c.GHOSTTY_KEY_SPACE));
    try std.testing.expect(isFunctional(c.GHOSTTY_KEY_ARROW_UP));
    try std.testing.expect(isFunctional(c.GHOSTTY_KEY_ENTER));
}
