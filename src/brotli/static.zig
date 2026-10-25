//! Every static dictionary match at a position, for qualities 10-11: the
//! reference encoder's `BrotliFindAllStaticDictionaryMatches`. For each
//! length, the smallest code (distance past the window times 32, plus the
//! word's length when the match is shorter) of a word under one of the
//! transforms that reaches it: the word itself, cut by 1-9 bytes at its
//! end, uppercased, and with the common prefixes and suffixes.

const dictionary = @import("dictionary.zig");
const find = @import("find.zig");
const words = @import("words.zig");

pub const max_match_len = 37;
pub const invalid_match: u32 = 0xFFFFFFF;

const cutoff_transforms: u64 = 0x071B520A_DA2D3200;
const uppercase_first = 10;

inline fn addMatch(distance: usize, len: usize, len_code: usize, matches: *[max_match_len + 1]u32) void {
    const m: u32 = @intCast((distance << 5) + len_code);
    matches[len] = @min(matches[len], m);
}

fn wordAt(len: usize, idx: usize) []const u8 {
    return dictionary.data[dictionary.offsets[len] + len * idx ..][0..len];
}

/// Whether `data` starts with the word under its transform.
fn isMatch(w: words.Word, data: []const u8, max_length: usize) bool {
    if (w.len > max_length) return false;
    const dict = wordAt(w.len, w.idx);
    if (w.transform == 0) return find.matchLengthIn(dict, data, w.len) == w.len;
    if (w.transform == uppercase_first) {
        // The lookup's uppercase words are all ASCII.
        return dict[0] >= 'a' and dict[0] <= 'z' and (dict[0] ^ 32) == data[0] and
            find.matchLengthIn(dict[1..], data[1..], w.len - 1) == w.len - 1;
    }
    for (dict, data[0..w.len]) |c, d| {
        if (c >= 'a' and c <= 'z') {
            if (c ^ 32 != d) return false;
        } else if (c != d) return false;
    }
    return true;
}

/// The words listed under the hash of `data[at..]`, as `Bucket`s yield.
const Bucket = struct {
    offset: usize,
    end: bool,

    fn init(data: []const u8, at: usize) Bucket {
        const offset = words.bucketStart(words.hash15(data, at));
        return .{ .offset = offset, .end = offset == 0 };
    }

    fn next(b: *Bucket) ?words.Word {
        if (b.end) return null;
        var w = words.lutWord(b.offset);
        b.offset += 1;
        b.end = w.len & 0x80 != 0;
        w.len &= 0x1f;
        return w;
    }
};

/// Fill `matches` (all `invalid_match` on entry) with the matches of
/// `min_length` to `max_length` at the start of `data` (which has at least
/// `max_length` bytes and slack past them); true when there is one.
pub fn findAll(data: []const u8, min_length: usize, max_length: usize, matches: *[max_match_len + 1]u32) bool {
    var found = plain(data, min_length, max_length, matches);
    found = afterOne(data, max_length, matches) or found;
    found = afterTwo(data, max_length, matches) or found;
    found = afterFive(data, max_length, matches) or found;
    return found;
}

/// The words at the start, whole, cut and with suffixes.
fn plain(data: []const u8, min_length: usize, max_length: usize, matches: *[max_match_len + 1]u32) bool {
    var found = false;
    var bucket: Bucket = .init(data, 0);
    while (bucket.next()) |w| {
        const l: usize = w.len;
        const n = @as(usize, 1) << dictionary.size_bits[l];
        const id: usize = w.idx;
        if (w.transform == 0) {
            const matchlen = find.matchLengthIn(wordAt(l, id), data, @min(l, max_length));
            // The word, then it cut by one ("" and "ing ").
            if (matchlen == l) {
                addMatch(id, l, l, matches);
                found = true;
            }
            if (matchlen >= l - 1) {
                addMatch(id + 12 * n, l - 1, l, matches);
                if (l + 2 < max_length and data[l - 1] == 'i' and data[l] == 'n' and data[l + 1] == 'g' and data[l + 2] == ' ') {
                    addMatch(id + 49 * n, l + 3, l, matches);
                }
                found = true;
            }
            // Cut by 2-9.
            var minlen = min_length;
            if (l > 9) minlen = @max(minlen, l - 9);
            const maxlen = @min(matchlen, l - 2);
            var len = minlen;
            while (len <= maxlen) : (len += 1) {
                const cut = l - len;
                const transform_id = (cut << 2) + @as(usize, @intCast((cutoff_transforms >> @intCast(cut * 6)) & 0x3f));
                addMatch(id + transform_id * n, len, l, matches);
                found = true;
            }
            if (matchlen < l or l + 6 >= max_length) continue;
            identitySuffixes(data[l..], id, l, n, matches);
        } else {
            const all_caps = w.transform != uppercase_first;
            if (!isMatch(w, data, max_length)) continue;
            addMatch(id + @as(usize, if (all_caps) 44 else 9) * n, l, l, matches);
            found = true;
            if (l + 1 >= max_length) continue;
            uppercaseSuffixes(data[l..], id, l, n, all_caps, matches);
        }
    }
    return found;
}

/// The words after " " and ".".
fn afterOne(data: []const u8, max_length: usize, matches: *[max_match_len + 1]u32) bool {
    var found = false;
    // The prefixes " " and ".".
    if (max_length >= 5 and (data[0] == ' ' or data[0] == '.')) {
        const space = data[0] == ' ';
        var bucket: Bucket = .init(data, 1);
        while (bucket.next()) |w| {
            const l: usize = w.len;
            const n = @as(usize, 1) << dictionary.size_bits[l];
            const id: usize = w.idx;
            if (w.transform == 0) {
                if (!isMatch(w, data[1..], max_length - 1)) continue;
                addMatch(id + @as(usize, if (space) 6 else 32) * n, l + 1, l, matches);
                found = true;
                if (l + 2 >= max_length) continue;
                const s = data[l + 1 ..];
                if (s[0] == ' ') {
                    addMatch(id + @as(usize, if (space) 2 else 77) * n, l + 2, l, matches);
                } else if (s[0] == '(') {
                    addMatch(id + @as(usize, if (space) 89 else 67) * n, l + 2, l, matches);
                } else if (space) {
                    if (s[0] == ',') {
                        addMatch(id + 103 * n, l + 2, l, matches);
                        if (s[1] == ' ') addMatch(id + 33 * n, l + 3, l, matches);
                    } else if (s[0] == '.') {
                        addMatch(id + 71 * n, l + 2, l, matches);
                        if (s[1] == ' ') addMatch(id + 52 * n, l + 3, l, matches);
                    } else if (s[0] == '=') {
                        if (s[1] == '"') {
                            addMatch(id + 81 * n, l + 3, l, matches);
                        } else if (s[1] == '\'') addMatch(id + 98 * n, l + 3, l, matches);
                    }
                }
            } else if (space) {
                const all_caps = w.transform != uppercase_first;
                if (!isMatch(w, data[1..], max_length - 1)) continue;
                addMatch(id + @as(usize, if (all_caps) 85 else 30) * n, l + 1, l, matches);
                found = true;
                if (l + 2 >= max_length) continue;
                const s = data[l + 1 ..];
                if (s[0] == ' ') {
                    addMatch(id + @as(usize, if (all_caps) 83 else 15) * n, l + 2, l, matches);
                } else if (s[0] == ',') {
                    if (!all_caps) addMatch(id + 109 * n, l + 2, l, matches);
                    if (s[1] == ' ') addMatch(id + @as(usize, if (all_caps) 111 else 65) * n, l + 3, l, matches);
                } else if (s[0] == '.') {
                    addMatch(id + @as(usize, if (all_caps) 115 else 96) * n, l + 2, l, matches);
                    if (s[1] == ' ') addMatch(id + @as(usize, if (all_caps) 117 else 91) * n, l + 3, l, matches);
                } else if (s[0] == '=') {
                    if (s[1] == '"') {
                        addMatch(id + @as(usize, if (all_caps) 110 else 118) * n, l + 3, l, matches);
                    } else if (s[1] == '\'') addMatch(id + @as(usize, if (all_caps) 119 else 120) * n, l + 3, l, matches);
                }
            }
        }
    }
    return found;
}

/// The words after "e ", "s ", ", " and a no-break space.
fn afterTwo(data: []const u8, max_length: usize, matches: *[max_match_len + 1]u32) bool {
    var found = false;
    // The prefixes "e ", "s ", ", " and a no-break space.
    if (max_length >= 6 and ((data[1] == ' ' and (data[0] == 'e' or data[0] == 's' or data[0] == ',')) or (data[0] == 0xC2 and data[1] == 0xA0))) {
        var bucket: Bucket = .init(data, 2);
        while (bucket.next()) |w| {
            const l: usize = w.len;
            const n = @as(usize, 1) << dictionary.size_bits[l];
            const id: usize = w.idx;
            if (w.transform != 0 or !isMatch(w, data[2..], max_length - 2)) continue;
            if (data[0] == 0xC2) {
                addMatch(id + 102 * n, l + 2, l, matches);
                found = true;
            } else if (l + 2 < max_length and data[l + 2] == ' ') {
                const t: usize = if (data[0] == 'e') 18 else if (data[0] == 's') 7 else 13;
                addMatch(id + t * n, l + 3, l, matches);
                found = true;
            }
        }
    }
    return found;
}

/// The words after " the " and ".com/".
fn afterFive(data: []const u8, max_length: usize, matches: *[max_match_len + 1]u32) bool {
    var found = false;
    // The prefixes " the " and ".com/".
    if (max_length >= 9 and ((data[0] == ' ' and data[1] == 't' and data[2] == 'h' and data[3] == 'e' and data[4] == ' ') or
        (data[0] == '.' and data[1] == 'c' and data[2] == 'o' and data[3] == 'm' and data[4] == '/')))
    {
        var bucket: Bucket = .init(data, 5);
        while (bucket.next()) |w| {
            const l: usize = w.len;
            const n = @as(usize, 1) << dictionary.size_bits[l];
            const id: usize = w.idx;
            if (w.transform != 0 or !isMatch(w, data[5..], max_length - 5)) continue;
            addMatch(id + @as(usize, if (data[0] == ' ') 41 else 72) * n, l + 5, l, matches);
            found = true;
            if (l + 5 < max_length and data[0] == ' ') {
                const s = data[l + 5 ..];
                if (l + 8 < max_length and s[0] == ' ' and s[1] == 'o' and s[2] == 'f' and s[3] == ' ') {
                    addMatch(id + 62 * n, l + 9, l, matches);
                    if (l + 12 < max_length and s[4] == 't' and s[5] == 'h' and s[6] == 'e' and s[7] == ' ') {
                        addMatch(id + 73 * n, l + 13, l, matches);
                    }
                }
            }
        }
    }
    return found;
}

/// The word followed by one of the identity transform's suffixes.
fn identitySuffixes(s: []const u8, id: usize, l: usize, n: usize, matches: *[max_match_len + 1]u32) void {
    switch (s[0]) {
        ' ' => {
            addMatch(id + n, l + 1, l, matches);
            switch (s[1]) {
                'a' => {
                    if (s[2] == ' ') {
                        addMatch(id + 28 * n, l + 3, l, matches);
                    } else if (s[2] == 's') {
                        if (s[3] == ' ') addMatch(id + 46 * n, l + 4, l, matches);
                    } else if (s[2] == 't') {
                        if (s[3] == ' ') addMatch(id + 60 * n, l + 4, l, matches);
                    } else if (s[2] == 'n') {
                        if (s[3] == 'd' and s[4] == ' ') addMatch(id + 10 * n, l + 5, l, matches);
                    }
                },
                'b' => if (s[2] == 'y' and s[3] == ' ') addMatch(id + 38 * n, l + 4, l, matches),
                'i' => {
                    if (s[2] == 'n') {
                        if (s[3] == ' ') addMatch(id + 16 * n, l + 4, l, matches);
                    } else if (s[2] == 's') {
                        if (s[3] == ' ') addMatch(id + 47 * n, l + 4, l, matches);
                    }
                },
                'f' => {
                    if (s[2] == 'o') {
                        if (s[3] == 'r' and s[4] == ' ') addMatch(id + 25 * n, l + 5, l, matches);
                    } else if (s[2] == 'r') {
                        if (s[3] == 'o' and s[4] == 'm' and s[5] == ' ') addMatch(id + 37 * n, l + 6, l, matches);
                    }
                },
                'o' => {
                    if (s[2] == 'f') {
                        if (s[3] == ' ') addMatch(id + 8 * n, l + 4, l, matches);
                    } else if (s[2] == 'n') {
                        if (s[3] == ' ') addMatch(id + 45 * n, l + 4, l, matches);
                    }
                },
                'n' => if (s[2] == 'o' and s[3] == 't' and s[4] == ' ') addMatch(id + 80 * n, l + 5, l, matches),
                't' => {
                    if (s[2] == 'h') {
                        if (s[3] == 'e') {
                            if (s[4] == ' ') addMatch(id + 5 * n, l + 5, l, matches);
                        } else if (s[3] == 'a') {
                            if (s[4] == 't' and s[5] == ' ') addMatch(id + 29 * n, l + 6, l, matches);
                        }
                    } else if (s[2] == 'o') {
                        if (s[3] == ' ') addMatch(id + 17 * n, l + 4, l, matches);
                    }
                },
                'w' => if (s[2] == 'i' and s[3] == 't' and s[4] == 'h' and s[5] == ' ') addMatch(id + 35 * n, l + 6, l, matches),
                else => {},
            }
        },
        '"' => {
            addMatch(id + 19 * n, l + 1, l, matches);
            if (s[1] == '>') addMatch(id + 21 * n, l + 2, l, matches);
        },
        '.' => {
            addMatch(id + 20 * n, l + 1, l, matches);
            if (s[1] == ' ') {
                addMatch(id + 31 * n, l + 2, l, matches);
                if (s[2] == 'T' and s[3] == 'h') {
                    if (s[4] == 'e') {
                        if (s[5] == ' ') addMatch(id + 43 * n, l + 6, l, matches);
                    } else if (s[4] == 'i') {
                        if (s[5] == 's' and s[6] == ' ') addMatch(id + 75 * n, l + 7, l, matches);
                    }
                }
            }
        },
        ',' => {
            addMatch(id + 76 * n, l + 1, l, matches);
            if (s[1] == ' ') addMatch(id + 14 * n, l + 2, l, matches);
        },
        '\n' => {
            addMatch(id + 22 * n, l + 1, l, matches);
            if (s[1] == '\t') addMatch(id + 50 * n, l + 2, l, matches);
        },
        ']' => addMatch(id + 24 * n, l + 1, l, matches),
        '\'' => addMatch(id + 36 * n, l + 1, l, matches),
        ':' => addMatch(id + 51 * n, l + 1, l, matches),
        '(' => addMatch(id + 57 * n, l + 1, l, matches),
        '=' => {
            if (s[1] == '"') {
                addMatch(id + 70 * n, l + 2, l, matches);
            } else if (s[1] == '\'') addMatch(id + 86 * n, l + 2, l, matches);
        },
        'a' => if (s[1] == 'l' and s[2] == ' ') addMatch(id + 84 * n, l + 3, l, matches),
        'e' => {
            if (s[1] == 'd') {
                if (s[2] == ' ') addMatch(id + 53 * n, l + 3, l, matches);
            } else if (s[1] == 'r') {
                if (s[2] == ' ') addMatch(id + 82 * n, l + 3, l, matches);
            } else if (s[1] == 's') {
                if (s[2] == 't' and s[3] == ' ') addMatch(id + 95 * n, l + 4, l, matches);
            }
        },
        'f' => if (s[1] == 'u' and s[2] == 'l' and s[3] == ' ') addMatch(id + 90 * n, l + 4, l, matches),
        'i' => {
            if (s[1] == 'v') {
                if (s[2] == 'e' and s[3] == ' ') addMatch(id + 92 * n, l + 4, l, matches);
            } else if (s[1] == 'z') {
                if (s[2] == 'e' and s[3] == ' ') addMatch(id + 100 * n, l + 4, l, matches);
            }
        },
        'l' => {
            if (s[1] == 'e') {
                if (s[2] == 's' and s[3] == 's' and s[4] == ' ') addMatch(id + 93 * n, l + 5, l, matches);
            } else if (s[1] == 'y') {
                if (s[2] == ' ') addMatch(id + 61 * n, l + 3, l, matches);
            }
        },
        'o' => if (s[1] == 'u' and s[2] == 's' and s[3] == ' ') addMatch(id + 106 * n, l + 4, l, matches),
        else => {},
    }
}

/// The uppercased word followed by one of its transforms' suffixes.
fn uppercaseSuffixes(s: []const u8, id: usize, l: usize, n: usize, all_caps: bool, matches: *[max_match_len + 1]u32) void {
    const pick = struct {
        inline fn f(caps: bool, a: usize, b: usize) usize {
            return if (caps) a else b;
        }
    }.f;
    switch (s[0]) {
        ' ' => addMatch(id + pick(all_caps, 68, 4) * n, l + 1, l, matches),
        '"' => {
            addMatch(id + pick(all_caps, 87, 66) * n, l + 1, l, matches);
            if (s[1] == '>') addMatch(id + pick(all_caps, 97, 69) * n, l + 2, l, matches);
        },
        '.' => {
            addMatch(id + pick(all_caps, 101, 79) * n, l + 1, l, matches);
            if (s[1] == ' ') addMatch(id + pick(all_caps, 114, 88) * n, l + 2, l, matches);
        },
        ',' => {
            addMatch(id + pick(all_caps, 112, 99) * n, l + 1, l, matches);
            if (s[1] == ' ') addMatch(id + pick(all_caps, 107, 58) * n, l + 2, l, matches);
        },
        '\'' => addMatch(id + pick(all_caps, 94, 74) * n, l + 1, l, matches),
        '(' => addMatch(id + pick(all_caps, 113, 78) * n, l + 1, l, matches),
        '=' => {
            if (s[1] == '"') {
                addMatch(id + pick(all_caps, 105, 104) * n, l + 2, l, matches);
            } else if (s[1] == '\'') addMatch(id + pick(all_caps, 116, 108) * n, l + 2, l, matches);
        },
        else => {},
    }
}
