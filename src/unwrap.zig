//! A stream in its wrapper, decoded: which wrapper the input has, zlib's
//! and gzip's headers and trailers, and gzip's members, around the decode
//! engine. One machine for every decoder: the whole-buffer decoder runs it
//! over all its input at once, the streaming ones resume it call after
//! call, so every decoder accepts and refuses the same streams for the
//! same reasons.
//!
//! The machine reads in the engine's units and tells the engine's source
//! after each (`commit`), as the engine does; bytes of a gzip header are
//! read a piece at a time and never need to be read again.

const inflate = @import("inflate.zig");
const checksum = @import("checksum.zig");
const container = @import("container.zig");
const gzip = @import("gzip.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Error = error{
    InvalidStream,
    ChecksumMismatch,
    DictionaryMismatch,
    Truncated,
    OutputTooSmall,
};

pub const Options = struct {
    accept: container.Accept,
    dictionary: []const u8 = &.{},
    members: container.Members = .all,
    /// The window the decoder keeps, in bits: a zlib header naming a
    /// larger one is refused.
    window_bits: u4 = 15,
    /// A raw stream reaches into the history already in place (a streaming
    /// decoder reset to keep it), not into `dictionary`.
    keep_history: bool = false,
    /// Where the first gzip member's header fields go.
    fields: ?*gzip.Fields = null,
};

/// How a run ended.
pub const Status = enum {
    /// The stream ended: the last member, or the only one.
    done,
    /// A block ended inside the stream.
    block_end,
    /// A gzip member ended, and another may follow (`members = .all`).
    member_end,
    /// The output is full.
    output_full,
};

const Phase = enum { detect, zlib_header, dictionary_id, gzip_header, body, zlib_trailer, gzip_crc, gzip_size, member_end, done };

/// Where a stream is: the wrapper's part, the engine's state inside the
/// body, the member's running checksum and length.
pub const State = struct {
    phase: Phase = .detect,
    wrapper: container.Container = .raw,
    engine: inflate.State = .{},
    /// The Adler-32 or CRC-32 of the member's output so far, and its
    /// length modulo 2^32.
    check: u32 = 0,
    size: u32 = 0,
    /// Where in the output the checksum has reached.
    checked: usize = 0,
    /// gzip members finished.
    members: u32 = 0,
    /// The bit at which the member after the last one started, for a
    /// refusal of what follows it.
    member_offset: u64 = 0,
    header: gzip.Parser = .{},
    /// The history changed in the last run: a dictionary, or a new
    /// member's empty one, replaced it.
    history_replaced: bool = false,

    /// Count the output written since the last call, into the checksum.
    pub fn sum(st: *State, s: *const inflate.Stream) void {
        const bytes = s.out[st.checked..s.op];
        st.checked = s.op;
        switch (st.wrapper) {
            .raw => {},
            .zlib => st.check = checksum.adler32(st.check, bytes),
            .gzip => {
                st.check = checksum.crc32(st.check, bytes);
                // safe: ISIZE is the length modulo 2^32
                st.size +%= @truncate(bytes.len);
            },
        }
    }

    /// Whether the stream is complete where it stands: at its end, or
    /// between gzip members.
    pub fn complete(st: *const State) bool {
        return st.phase == .done or st.phase == .member_end;
    }
};

/// Run until the stream ends, a block or member ends, or the output is
/// full. The output written is in the checksum when this returns; after an
/// error, `State.sum` brings it up to date.
pub fn run(t: *inflate.Tables, st: *State, s: *inflate.Stream, source: anytype, options: Options) Error!Status {
    st.checked = s.op;
    st.history_replaced = false;
    // Each part goes on to the next by a direct jump: one indirect jump
    // shared by every part would be mispredicted at each.
    phase: switch (st.phase) {
        .detect => switch (try detect(st, s, source, options)) {
            .raw => continue :phase .body,
            .zlib => continue :phase .zlib_header,
            .gzip => continue :phase .gzip_header,
        },
        .zlib_header => if (try zlibHeader(st, s, source, options)) continue :phase .dictionary_id else continue :phase .body,
        .dictionary_id => {
            try dictionaryId(st, s, source, options);
            continue :phase .body;
        },
        .gzip_header => {
            try gzipHeader(st, s, source, options);
            continue :phase .body;
        },
        .body => {
            const status = try inflate.decode(t, s, source, &st.engine);
            st.sum(s);
            switch (status) {
                .block_end => return .block_end,
                .output_full => return .output_full,
                .done => switch (st.wrapper) {
                    .raw => {
                        st.phase = .done;
                        return .done;
                    },
                    .zlib => continue :phase .zlib_trailer,
                    .gzip => continue :phase .gzip_crc,
                },
            }
        },
        .zlib_trailer => {
            st.phase = .zlib_trailer;
            s.consume(@intCast(s.bitsleft & 7));
            const want = @byteSwap(try s.take(source, 32));
            if (st.check != want) return mismatch(s, .adler32);
            st.phase = .done;
            source.commit(s);
            return .done;
        },
        .gzip_crc => {
            st.phase = .gzip_crc;
            s.consume(@intCast(s.bitsleft & 7));
            // Each check as soon as its bytes are read, as zlib makes them.
            if (st.check != try s.take(source, 32)) return mismatch(s, .crc32);
            st.phase = .gzip_size;
            source.commit(s);
            continue :phase .gzip_size;
        },
        .gzip_size => {
            if (st.size != try s.take(source, 32)) return mismatch(s, .size);
            st.members += 1;
            st.phase = if (options.members == .one) .done else .member_end;
            st.member_offset = s.bitOffset();
            source.commit(s);
            return if (st.phase == .done) .done else .member_end;
        },
        .member_end => {
            // Called again with input: what follows is another member, or
            // refused.
            st.phase = .gzip_header;
            st.header = .{};
            continue :phase .gzip_header;
        },
        .done => return .done,
    }
}

/// Which wrapper: given, or told from the first two bytes.
fn detect(st: *State, s: *inflate.Stream, source: anytype, options: Options) Error!container.Container {
    const wrapper: container.Container = switch (options.accept) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
        .zlib_or_raw, .gzip_or_zlib => blk: {
            // Two bytes decide; with fewer the stream is cut short.
            s.need(source, 16);
            if (s.bitsleft < 8 * s.virtual + 16) return s.failEnd();
            const first = [2]u8{ @truncate(s.bitbuf), @truncate(s.bitbuf >> 8) };
            break :blk container.detect(options.accept, &first);
        },
    };
    st.wrapper = wrapper;
    st.check = if (wrapper == .zlib) 1 else 0;
    st.size = 0;
    switch (wrapper) {
        .raw => {
            if (!options.keep_history) replaceHistory(st, s, options.dictionary);
            st.phase = .body;
        },
        .zlib => st.phase = .zlib_header,
        .gzip => {
            st.header = .{};
            st.phase = .gzip_header;
        },
    }
    return wrapper;
}

fn replaceHistory(st: *State, s: *inflate.Stream, history: []const u8) void {
    s.history = .{ .newer = history };
    st.history_replaced = true;
}

/// A zlib header; whether a dictionary's id follows it.
fn zlibHeader(st: *State, s: *inflate.Stream, source: anytype, options: Options) Error!bool {
    const header = try s.take(source, 16);
    const cmf: u8 = @truncate(header);
    const flg: u8 = @truncate(header >> 8);
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0 or cmf & 15 != 8 or (cmf >> 4) + 8 > options.window_bits) return s.fail(.bad_zlib_header);
    if (flg & 0x20 != 0) {
        st.phase = .dictionary_id;
    } else {
        if (!options.keep_history) replaceHistory(st, s, &.{});
        st.phase = .body;
    }
    source.commit(s);
    return st.phase == .dictionary_id;
}

/// The Adler-32 of the dictionary a zlib stream names.
fn dictionaryId(st: *State, s: *inflate.Stream, source: anytype, options: Options) Error!void {
    // Big-endian, as the trailer.
    const id = @byteSwap(try s.take(source, 32));
    if (options.dictionary.len == 0) return s.fail(.dictionary_required);
    if (checksum.adler32(1, options.dictionary) != id) {
        if (s.diagnostic) |diag| diag.* = .{ .bit_offset = s.bitOffset(), .reason = .dictionary_mismatch };
        return error.DictionaryMismatch;
    }
    replaceHistory(st, s, options.dictionary);
    st.phase = .body;
    source.commit(s);
}

/// A gzip member's header, read a piece at a time: the whole bytes the bit
/// buffer holds first, then the input itself.
fn gzipHeader(st: *State, s: *inflate.Stream, source: anytype, options: Options) Error!void {
    s.consume(@intCast(s.bitsleft & 7));
    const fields = if (st.members == 0) options.fields else null;
    while (s.bitsleft >= 8 and s.bitsleft > 8 * s.virtual) {
        const byte = [1]u8{@truncate(s.bitbuf)};
        if (trailing(st, byte[0])) return refuse(st, s, .bad_gzip_header);
        s.consume(8);
        const fed = feed(st, &byte, fields);
        if (fed.status == .invalid) return refuse(st, s, fed.reason);
        source.commit(s);
        if (fed.status == .done) return headerDone(st, s, fields);
    }
    // Only zero bytes past the end, if anything, are left in hand.
    s.ip -= s.virtual;
    s.virtual = 0;
    s.bitbuf = 0;
    s.bitsleft = 0;
    while (true) {
        if (s.ip >= s.in.len and !source.more(s)) return s.failEnd();
        if (trailing(st, s.in[s.ip])) return refuse(st, s, .bad_gzip_header);
        const fed = feed(st, s.in[s.ip..], fields);
        s.ip += fed.used;
        if (fed.status == .invalid) return refuse(st, s, fed.reason);
        source.commit(s);
        if (fed.status == .done) return headerDone(st, s, fields);
    }
}

fn feed(st: *State, bytes: []const u8, fields: ?*gzip.Fields) gzip.Parser.Fed {
    if (fields) |f| return st.header.feed(bytes, f);
    return st.header.feed(bytes, gzip.skip);
}

/// A member's header is read: its body starts, with no history.
fn headerDone(st: *State, s: *inflate.Stream, fields: ?*gzip.Fields) void {
    if (fields) |f| {
        const h = st.header.header();
        f.header.text = h.text;
        f.header.mtime = h.mtime;
        f.header.xfl = h.xfl;
        f.header.os = h.os;
        f.header.header_crc = h.header_crc;
    }
    s.start = s.op;
    st.checked = s.op;
    replaceHistory(st, s, &.{});
    st.check = 0;
    st.size = 0;
    st.engine = .{};
    st.phase = .body;
}

/// A header refused: what follows a member and is not one is trailing
/// data, refused where it starts.
fn refuse(st: *State, s: *inflate.Stream, reason: Diagnostic.Reason) Error {
    if (st.members > 0 and st.header.part == .fixed and st.header.at <= 2 and reason == .bad_gzip_header) {
        if (s.diagnostic) |diag| diag.* = .{ .bit_offset = st.member_offset, .reason = .trailing_data };
        return error.InvalidStream;
    }
    if (reason == .header_crc) return mismatch(s, .header_crc);
    return s.fail(reason);
}

fn mismatch(s: *inflate.Stream, reason: Diagnostic.Reason) Error {
    if (s.diagnostic) |diag| diag.* = .{ .bit_offset = s.bitOffset(), .reason = reason };
    return error.ChecksumMismatch;
}

/// Whether `byte`, the first after a member, cannot start another: gzip's
/// magic is refused on its first byte there, where a stream's first member
/// waits for two.
fn trailing(st: *const State, byte: u8) bool {
    return st.members > 0 and st.header.part == .fixed and st.header.at == 0 and byte != 0x1f;
}
