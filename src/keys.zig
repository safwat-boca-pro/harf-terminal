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
        76 => c.GHOSTTY_KEY_NUMPAD_ENTER,
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

/// The character a text key types with no modifiers on a US layout, or 0 for other keys. The kitty
/// keyboard protocol identifies Ctrl combinations by it (Ctrl+C is `ESC [ 99 ; 5 u`); using the
/// physical key keeps Ctrl+C working on an Arabic layout.
pub fn unshiftedCodepoint(key: c.GhosttyKey) u21 {
    return switch (key) {
        c.GHOSTTY_KEY_A...c.GHOSTTY_KEY_Z => @intCast('a' + (key - c.GHOSTTY_KEY_A)),
        c.GHOSTTY_KEY_DIGIT_0...c.GHOSTTY_KEY_DIGIT_9 => @intCast('0' + (key - c.GHOSTTY_KEY_DIGIT_0)),
        c.GHOSTTY_KEY_BACKQUOTE => '`',
        c.GHOSTTY_KEY_BACKSLASH => '\\',
        c.GHOSTTY_KEY_BRACKET_LEFT => '[',
        c.GHOSTTY_KEY_BRACKET_RIGHT => ']',
        c.GHOSTTY_KEY_COMMA => ',',
        c.GHOSTTY_KEY_EQUAL => '=',
        c.GHOSTTY_KEY_MINUS => '-',
        c.GHOSTTY_KEY_PERIOD => '.',
        c.GHOSTTY_KEY_QUOTE => '\'',
        c.GHOSTTY_KEY_SEMICOLON => ';',
        c.GHOSTTY_KEY_SLASH => '/',
        c.GHOSTTY_KEY_SPACE => ' ',
        else => 0,
    };
}

/// Bytes zsh and readline already understand for the Option and Command editing keys (brief
/// section 5), or null if `key` with `mods` is not one of them. Only exact combinations match.
pub fn editorBytes(key: c.GhosttyKey, mods: u32) ?[]const u8 {
    return switch (mods & 0xF) {
        Mods.alt => switch (key) {
            c.GHOSTTY_KEY_ARROW_LEFT => "\x1bb",
            c.GHOSTTY_KEY_ARROW_RIGHT => "\x1bf",
            c.GHOSTTY_KEY_BACKSPACE => "\x1b\x7f",
            c.GHOSTTY_KEY_DELETE => "\x1bd",
            else => null,
        },
        Mods.super => switch (key) {
            c.GHOSTTY_KEY_ARROW_LEFT => "\x01",
            c.GHOSTTY_KEY_ARROW_RIGHT => "\x05",
            c.GHOSTTY_KEY_BACKSPACE => "\x15",
            c.GHOSTTY_KEY_DELETE => "\x0b",
            else => null,
        },
        else => null,
    };
}

/// The classic control code for Control plus the character `cp` (legacy keyboard mode), or null if
/// there is none. Digits 2 to 8 follow xterm.
pub fn controlByte(cp: u21) ?u8 {
    return switch (cp) {
        'a'...'z' => @intCast(cp - 'a' + 1),
        'A'...'Z' => @intCast(cp - 'A' + 1),
        '@', ' ', '2' => 0,
        '[', '3' => 0x1b,
        '\\', '4' => 0x1c,
        ']', '5' => 0x1d,
        '^', '6' => 0x1e,
        '_', '-', '/', '7' => 0x1f,
        '?', '8' => 0x7f,
        else => null,
    };
}

fn printableAscii(cp: u21) bool {
    return cp >= 0x20 and cp < 0x7f;
}

/// The character a Control combination is named by: what the layout types for the key (so AZERTY,
/// Dvorak and Colemak work), and the physical US key when the layout has no ASCII letter there
/// (an Arabic layout), so Ctrl+C stays Ctrl+C. `utf8` is the layout's text with Control removed;
/// `unshifted` is the layout's character with no modifiers (0 if unknown).
pub fn layoutCodepoint(utf8: []const u8, unshifted: u21, key: c.GhosttyKey) u21 {
    if (utf8.len > 0) {
        const n = std.unicode.utf8ByteSequenceLength(utf8[0]) catch 0;
        if (n > 0 and n <= utf8.len) {
            if (std.unicode.utf8Decode(utf8[0..n])) |cp| {
                if (printableAscii(cp)) return cp;
            } else |_| {}
        }
    }
    if (printableAscii(unshifted)) return unshifted;
    return unshiftedCodepoint(key);
}

test "known and unknown keycodes" {
    try std.testing.expectEqual(@as(?c.GhosttyKey, c.GHOSTTY_KEY_NUMPAD_ENTER), fromMac(76));
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

test "unshifted codepoints of text keys" {
    try std.testing.expectEqual(@as(u21, 'c'), unshiftedCodepoint(c.GHOSTTY_KEY_C));
    try std.testing.expectEqual(@as(u21, 'a'), unshiftedCodepoint(c.GHOSTTY_KEY_A));
    try std.testing.expectEqual(@as(u21, 'z'), unshiftedCodepoint(c.GHOSTTY_KEY_Z));
    try std.testing.expectEqual(@as(u21, '0'), unshiftedCodepoint(c.GHOSTTY_KEY_DIGIT_0));
    try std.testing.expectEqual(@as(u21, '9'), unshiftedCodepoint(c.GHOSTTY_KEY_DIGIT_9));
    try std.testing.expectEqual(@as(u21, ' '), unshiftedCodepoint(c.GHOSTTY_KEY_SPACE));
    try std.testing.expectEqual(@as(u21, '['), unshiftedCodepoint(c.GHOSTTY_KEY_BRACKET_LEFT));
    try std.testing.expectEqual(@as(u21, 0), unshiftedCodepoint(c.GHOSTTY_KEY_ARROW_UP));
    try std.testing.expectEqual(@as(u21, 0), unshiftedCodepoint(c.GHOSTTY_KEY_ENTER));
}

test "editor keys: Option and Command combinations (brief section 5)" {
    const alt = Mods.alt;
    const sup = Mods.super;
    try std.testing.expectEqualStrings("\x1bb", editorBytes(c.GHOSTTY_KEY_ARROW_LEFT, alt).?);
    try std.testing.expectEqualStrings("\x1bf", editorBytes(c.GHOSTTY_KEY_ARROW_RIGHT, alt).?);
    try std.testing.expectEqualStrings("\x1b\x7f", editorBytes(c.GHOSTTY_KEY_BACKSPACE, alt).?);
    try std.testing.expectEqualStrings("\x1bd", editorBytes(c.GHOSTTY_KEY_DELETE, alt).?);
    try std.testing.expectEqualStrings("\x01", editorBytes(c.GHOSTTY_KEY_ARROW_LEFT, sup).?);
    try std.testing.expectEqualStrings("\x05", editorBytes(c.GHOSTTY_KEY_ARROW_RIGHT, sup).?);
    try std.testing.expectEqualStrings("\x15", editorBytes(c.GHOSTTY_KEY_BACKSPACE, sup).?);
    try std.testing.expectEqualStrings("\x0b", editorBytes(c.GHOSTTY_KEY_DELETE, sup).?);
    // anything else is not an editor key
    try std.testing.expect(editorBytes(c.GHOSTTY_KEY_ARROW_LEFT, 0) == null);
    try std.testing.expect(editorBytes(c.GHOSTTY_KEY_ARROW_LEFT, alt | Mods.shift) == null);
    try std.testing.expect(editorBytes(c.GHOSTTY_KEY_ARROW_LEFT, alt | Mods.ctrl) == null);
    try std.testing.expect(editorBytes(c.GHOSTTY_KEY_ARROW_UP, alt) == null);
    try std.testing.expect(editorBytes(c.GHOSTTY_KEY_A, alt) == null);
}

test "control bytes" {
    try std.testing.expectEqual(@as(?u8, 3), controlByte('c'));
    try std.testing.expectEqual(@as(?u8, 3), controlByte('C'));
    try std.testing.expectEqual(@as(?u8, 0x1b), controlByte('['));
    try std.testing.expectEqual(@as(?u8, 0x1c), controlByte('\\'));
    try std.testing.expectEqual(@as(?u8, 0x1d), controlByte(']'));
    try std.testing.expectEqual(@as(?u8, 0x1e), controlByte('^'));
    try std.testing.expectEqual(@as(?u8, 0x1f), controlByte('_'));
    try std.testing.expectEqual(@as(?u8, 0x1f), controlByte('-'));
    try std.testing.expectEqual(@as(?u8, 0), controlByte('@'));
    try std.testing.expectEqual(@as(?u8, 0), controlByte(' '));
    try std.testing.expectEqual(@as(?u8, 0), controlByte('2'));
    try std.testing.expectEqual(@as(?u8, 0x1e), controlByte('6'));
    try std.testing.expectEqual(@as(?u8, 0x7f), controlByte('?'));
    try std.testing.expectEqual(@as(?u8, null), controlByte('.'));
    try std.testing.expectEqual(@as(?u8, null), controlByte('1'));
    try std.testing.expectEqual(@as(?u8, null), controlByte(0x624));
}

test "layout codepoint: the layout's letter, else the physical key" {
    try std.testing.expectEqual(@as(u21, 'a'), layoutCodepoint("a", 0, c.GHOSTTY_KEY_Q)); // AZERTY
    try std.testing.expectEqual(@as(u21, 'j'), layoutCodepoint("", 'j', c.GHOSTTY_KEY_C)); // unshifted only
    try std.testing.expectEqual(@as(u21, 'c'), layoutCodepoint("\u{624}", 0x624, c.GHOSTTY_KEY_C)); // Arabic: physical
    try std.testing.expectEqual(@as(u21, 'c'), layoutCodepoint("\x03", 0, c.GHOSTTY_KEY_C)); // a control character is not text
    try std.testing.expectEqual(@as(u21, 'a'), layoutCodepoint("", 0, c.GHOSTTY_KEY_A));
}
