const std = @import("std");

/// Escapes `s` into `out` as the *contents* of a JSON string (no surrounding
/// quotes), returning the escaped slice. Never writes past `out`.
///
/// This replaced a `sanitize()` that returned `"guest error"` whenever the
/// message contained a quote, a backslash or a newline — so every quoted guest
/// error lost its text — while letting other control bytes through and producing
/// JSON that strict parsers reject. Escaping is the fix; discarding is not.
///
/// Lives in `util/` because two layers need it: the HTTP error envelope and the
/// guest's `json` table. `vm/` must not import `http/`.
pub fn escapeInto(out: []u8, s: []const u8) []const u8 {
    var w: usize = 0;
    for (s) |c| {
        if (c == '"') {
            if (w + 2 > out.len) break;
            out[w] = '\\';
            out[w + 1] = '"';
            w += 2;
        } else if (c == '\\') {
            if (w + 2 > out.len) break;
            out[w] = '\\';
            out[w + 1] = '\\';
            w += 2;
        } else if (c == '\n') {
            if (w + 2 > out.len) break;
            out[w] = '\\';
            out[w + 1] = 'n';
            w += 2;
        } else if (c == '\r') {
            if (w + 2 > out.len) break;
            out[w] = '\\';
            out[w + 1] = 'r';
            w += 2;
        } else if (c == '\t') {
            if (w + 2 > out.len) break;
            out[w] = '\\';
            out[w + 1] = 't';
            w += 2;
        } else if (c < 0x20) {
            if (w + 6 > out.len) break;
            const hex = "0123456789abcdef";
            out[w] = '\\';
            out[w + 1] = 'u';
            out[w + 2] = '0';
            out[w + 3] = '0';
            out[w + 4] = hex[c >> 4];
            out[w + 5] = hex[c & 0x0f];
            w += 6;
        } else {
            if (w + 1 > out.len) break;
            out[w] = c;
            w += 1;
        }
    }
    return out[0..w];
}

/// Escapes into a growable buffer. Used by the guest `json` table, which cannot
/// know the encoded size in advance.
pub fn escapeIntoList(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    var hexbuf: [6]u8 = undefined;
                    const hex = "0123456789abcdef";
                    hexbuf[0] = '\\';
                    hexbuf[1] = 'u';
                    hexbuf[2] = '0';
                    hexbuf[3] = '0';
                    hexbuf[4] = hex[c >> 4];
                    hexbuf[5] = hex[c & 0x0f];
                    try out.appendSlice(a, &hexbuf);
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
}

/// Largest prefix of `s` no longer than `max` bytes that ends on a UTF-8 boundary,
/// so a truncated message is never invalid UTF-8.
pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    // Walk back over continuation bytes (10xxxxxx).
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

test "quotes, backslashes and newlines are escaped, not discarded" {
    var buf: [128]u8 = undefined;
    const got = escapeInto(&buf, "say \"hi\"\npath C:\\tmp\ttab");
    try std.testing.expectEqualStrings("say \\\"hi\\\"\\npath C:\\\\tmp\\ttab", got);
}

test "control bytes become \\u escapes" {
    var buf: [64]u8 = undefined;
    const got = escapeInto(&buf, "a\x01b\x1fc");
    try std.testing.expectEqualStrings("a\\u0001b\\u001fc", got);
}

test "output never exceeds the buffer, even mid-escape" {
    var buf: [8]u8 = undefined;
    const got = escapeInto(&buf, "aaaaaaaaaaaaaaaa\"");
    try std.testing.expectEqual(@as(usize, 8), got.len);
    try std.testing.expectEqualStrings("aaaaaaaa", got);

    var tiny: [3]u8 = undefined;
    const g2 = escapeInto(&tiny, "ab\x01cd");
    try std.testing.expectEqualStrings("ab", g2); // the 6-byte escape does not fit
}

test "truncation lands on a UTF-8 boundary" {
    const s = "ab\u{00e9}cd"; // é is two bytes
    try std.testing.expectEqualStrings("ab", utf8Prefix(s, 3));
    try std.testing.expectEqualStrings("ab\u{00e9}", utf8Prefix(s, 4));
    try std.testing.expectEqualStrings(s, utf8Prefix(s, 100));
}

test "growable escaping matches the fixed-buffer version" {
    const a = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(a);
    try escapeIntoList(a, &list, "a\"b\\c\nd\te\x01f");

    var buf: [128]u8 = undefined;
    const fixed = escapeInto(&buf, "a\"b\\c\nd\te\x01f");
    try std.testing.expectEqualStrings(fixed, list.items);
}
