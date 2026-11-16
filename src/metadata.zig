const std = @import("std");
const c = @import("c");

pub const TrackInfo = struct {
    title: ?[]u8 = null,
    artist: ?[]u8 = null,
    album: ?[]u8 = null,
    year: ?[]u8 = null,
    genre: ?[]u8 = null,
    track_number: ?u32 = null,
    duration_frames: u64 = 0,
    sample_rate: u32 = 0,
    bits_per_sample: u8 = 0,
    channels: u16 = 0,
    cover_data: ?[]u8 = null,
    cover_mime: ?[]u8 = null,

    pub fn deinit(self: *TrackInfo, allocator: std.mem.Allocator) void {
        if (self.title) |s| allocator.free(s);
        if (self.artist) |s| allocator.free(s);
        if (self.album) |s| allocator.free(s);
        if (self.year) |s| allocator.free(s);
        if (self.genre) |s| allocator.free(s);
        if (self.cover_data) |s| allocator.free(s);
        if (self.cover_mime) |s| allocator.free(s);
    }
};

pub fn readTrackInfo(allocator: std.mem.Allocator, path: [:0]const u8) TrackInfo {
    var info = TrackInfo{};
    if (std.mem.endsWith(u8, path, ".flac")) {
        readFlacMetadata(allocator, path, &info);
    } else if (std.mem.endsWith(u8, path, ".mp3")) {
        readMp3BasicInfo(path, &info);
    } else if (std.mem.endsWith(u8, path, ".wav")) {
        readWavBasicInfo(path, &info);
    }
    return info;
}

fn readFlacMetadata(allocator: std.mem.Allocator, path: [:0]const u8, info: *TrackInfo) void {
    const chain = c.FLAC__metadata_chain_new();
    if (chain == null) return;
    defer _ = c.FLAC__metadata_chain_delete(chain);

    if (c.FLAC__metadata_chain_read(chain, path.ptr) == 0) return;

    const iter = c.FLAC__metadata_iterator_new();
    if (iter == null) return;
    defer _ = c.FLAC__metadata_iterator_delete(iter);

    c.FLAC__metadata_iterator_init(iter, chain);

    while (c.FLAC__metadata_iterator_next(iter) != 0) {
        const block = c.FLAC__metadata_iterator_get_block(iter);
        if (block == null) continue;
        const meta = block[0];

        switch (meta.type) {
            c.FLAC__METADATA_TYPE_STREAMINFO => {
                const si = meta.data.stream_info;
                info.sample_rate = si.sample_rate;
                info.bits_per_sample = @intCast(si.bits_per_sample);
                info.channels = @intCast(si.channels);
                info.duration_frames = si.total_samples;
            },
            c.FLAC__METADATA_TYPE_VORBIS_COMMENT => {
                const vc = meta.data.vorbis_comment;
                const num: usize = vc.num_comments;
                for (0..num) |i| {
                    const entry_ptr = vc.comments[i].entry;
                    const entry_len: usize = vc.comments[i].length;
                    if (entry_ptr == null) continue;
                    const entry = entry_ptr[0..entry_len];
                    assignVorbisTag(allocator, info, entry);
                }
            },
            c.FLAC__METADATA_TYPE_PICTURE => {
                // Solo nos interesa la portada frontal (type 3).
                const pic = meta.data.picture;
                if (pic.type == c.FLAC__STREAM_METADATA_PICTURE_TYPE_FRONT_COVER) {
                    if (pic.mime_type != null) {
                        const mt_slice = std.mem.span(@as([*:0]const u8, @ptrCast(pic.mime_type)));
                        if (info.cover_mime) |s| allocator.free(s);
                        info.cover_mime = allocator.dupe(u8, mt_slice) catch null;
                    }
                    if (pic.data != null and pic.data_length > 0) {
                        const data_slice: []const u8 = @as([*]const u8, @ptrCast(pic.data))[0..pic.data_length];
                        if (info.cover_data) |s| allocator.free(s);
                        info.cover_data = allocator.dupe(u8, data_slice) catch null;
                    }
                }
            },
            else => {},
        }
    }
}

fn readMp3BasicInfo(path: [:0]const u8, info: *TrackInfo) void {
    var mp3: c.drmp3 = undefined;
    if (c.drmp3_init_file(&mp3, path.ptr, null) == 0) return;
    defer c.drmp3_uninit(&mp3);

    info.sample_rate = mp3.sampleRate;
    info.channels = @intCast(mp3.channels);
    info.bits_per_sample = 16;
    info.duration_frames = c.drmp3_get_pcm_frame_count(&mp3);
}

fn readWavBasicInfo(path: [:0]const u8, info: *TrackInfo) void {
    var wav: c.drwav = undefined;
    if (c.drwav_init_file(&wav, path.ptr, null) == 0) return;
    defer _ = c.drwav_uninit(&wav);

    info.sample_rate = wav.sampleRate;
    info.channels = @intCast(wav.channels);
    info.bits_per_sample = @intCast(wav.bitsPerSample);
    info.duration_frames = wav.totalPCMFrameCount;
}

fn assignVorbisTag(allocator: std.mem.Allocator, info: *TrackInfo, comment: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, comment, '=') orelse return;
    const key = comment[0..eq];
    const value = comment[eq + 1 ..];

    if (std.mem.eql(u8, key, "TITLE")) {
        if (info.title) |s| allocator.free(s);
        info.title = allocator.dupe(u8, value) catch null;
    } else if (std.mem.eql(u8, key, "ARTIST")) {
        if (info.artist) |s| allocator.free(s);
        info.artist = allocator.dupe(u8, value) catch null;
    } else if (std.mem.eql(u8, key, "ALBUM")) {
        if (info.album) |s| allocator.free(s);
        info.album = allocator.dupe(u8, value) catch null;
    } else if (std.mem.eql(u8, key, "DATE") or std.mem.eql(u8, key, "YEAR")) {
        if (info.year) |s| allocator.free(s);
        info.year = allocator.dupe(u8, value) catch null;
    } else if (std.mem.eql(u8, key, "GENRE")) {
        if (info.genre) |s| allocator.free(s);
        info.genre = allocator.dupe(u8, value) catch null;
    } else if (std.mem.eql(u8, key, "TRACKNUMBER")) {
        info.track_number = std.fmt.parseInt(u32, value, 10) catch null;
    }
}
