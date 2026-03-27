const std = @import("std");

/// Increment when the cache schema or rendered HTML output format changes.
/// Existing caches with a different version are silently discarded.
const CACHE_VERSION: u32 = 1;

pub const CACHE_FILENAME = ".zkdocs-cache";

/// File path → last-seen mtime in seconds since Unix epoch.
const FileMap = std.StringHashMap(i64);

/// Persistent build cache. Tracks mtimes of source files, guide files, and
/// the conf file so that unchanged outputs can be skipped on the next run.
///
/// All string keys in the maps are heap-allocated and owned by the Cache.
/// Call `deinit` when done.
pub const Cache = struct {
    allocator: std.mem.Allocator,

    /// Absolute path to the zkdocs.conf recorded in the cache, or null when
    /// docs were generated without a conf file.
    conf_path: ?[]const u8,
    conf_mtime: i64,

    /// Absolute source .zig paths → mtime.
    sources: FileMap,
    /// Absolute guide .md paths → mtime.
    guides: FileMap,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .allocator = allocator,
            .conf_path = null,
            .conf_mtime = 0,
            .sources = FileMap.init(allocator),
            .guides = FileMap.init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        if (self.conf_path) |p| self.allocator.free(p);
        freeMap(self.allocator, &self.sources);
        freeMap(self.allocator, &self.guides);
    }

    fn freeMap(allocator: std.mem.Allocator, map: *FileMap) void {
        var it = map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        map.deinit();
    }

    // ── Load / Save ──────────────────────────────────────────────────────────

    /// Load cache from `<out_dir_path>/.zkdocs-cache`.
    /// Never fails: returns an empty cache on any error (missing file, bad JSON,
    /// wrong version, etc.).
    pub fn load(allocator: std.mem.Allocator, out_dir_path: []const u8) Cache {
        return loadInner(allocator, out_dir_path) catch Cache.init(allocator);
    }

    fn loadInner(allocator: std.mem.Allocator, out_dir_path: []const u8) !Cache {
        const cache_path = try std.fs.path.join(allocator, &.{ out_dir_path, CACHE_FILENAME });
        defer allocator.free(cache_path);

        const raw = try std.fs.cwd().readFileAlloc(allocator, cache_path, 512 * 1024);
        defer allocator.free(raw);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.Invalid;
        const obj = parsed.value.object;

        // Version check — mismatched version means stale or incompatible cache.
        const vj = obj.get("v") orelse return error.Invalid;
        if (vj != .integer or vj.integer != CACHE_VERSION) return error.VersionMismatch;

        var cache = Cache.init(allocator);
        errdefer cache.deinit();

        if (obj.get("conf_path")) |cp| if (cp == .string) {
            cache.conf_path = try allocator.dupe(u8, cp.string);
        };
        if (obj.get("conf_mtime")) |cm| if (cm == .integer) {
            cache.conf_mtime = cm.integer;
        };

        if (obj.get("sources")) |sv| if (sv == .object) {
            var it = sv.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .integer) continue;
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                try cache.sources.put(key, entry.value_ptr.*.integer);
            }
        };

        if (obj.get("guides")) |gv| if (gv == .object) {
            var it = gv.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .integer) continue;
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                try cache.guides.put(key, entry.value_ptr.*.integer);
            }
        };

        return cache;
    }

    /// Save the cache to `<out_dir_path>/.zkdocs-cache` atomically via a
    /// temp-file rename.  Errors are non-fatal; the caller should warn but
    /// continue.
    pub fn save(self: *const Cache, out_dir_path: []const u8) !void {
        const cache_path = try std.fs.path.join(self.allocator, &.{ out_dir_path, CACHE_FILENAME });
        defer self.allocator.free(cache_path);

        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.print("{{\"v\":{d}", .{CACHE_VERSION});

        try w.writeAll(",\"conf_path\":");
        if (self.conf_path) |p| try jsonWriteStr(w, p) else try w.writeAll("null");
        try w.print(",\"conf_mtime\":{d}", .{self.conf_mtime});

        try w.writeAll(",\"sources\":{");
        var first = true;
        var sit = self.sources.iterator();
        while (sit.next()) |e| {
            if (!first) try w.writeByte(',');
            first = false;
            try jsonWriteStr(w, e.key_ptr.*);
            try w.print(":{d}", .{e.value_ptr.*});
        }
        try w.writeByte('}');

        try w.writeAll(",\"guides\":{");
        first = true;
        var git = self.guides.iterator();
        while (git.next()) |e| {
            if (!first) try w.writeByte(',');
            first = false;
            try jsonWriteStr(w, e.key_ptr.*);
            try w.print(":{d}", .{e.value_ptr.*});
        }
        try w.writeAll("}}\n");

        // Atomic write: write to a temp file then rename into place.
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{cache_path});
        defer self.allocator.free(tmp_path);
        {
            const f = try std.fs.cwd().createFile(tmp_path, .{});
            defer f.close();
            try f.writeAll(buf.items);
        }
        try std.fs.cwd().rename(tmp_path, cache_path);
    }

    // ── Query ────────────────────────────────────────────────────────────────

    /// True if `abs_path` is in the sources map and its current mtime matches.
    pub fn sourceUnchanged(self: *const Cache, abs_path: []const u8) bool {
        return mapEntryUnchanged(&self.sources, abs_path);
    }

    /// True if `abs_path` is in the guides map and its current mtime matches.
    pub fn guideUnchanged(self: *const Cache, abs_path: []const u8) bool {
        return mapEntryUnchanged(&self.guides, abs_path);
    }

    /// True if the conf at `abs_path` matches the cached conf path and mtime.
    pub fn confUnchanged(self: *const Cache, abs_path: []const u8) bool {
        const cached_path = self.conf_path orelse return false;
        if (!std.mem.eql(u8, cached_path, abs_path)) return false;
        const mt = fileMtime(abs_path) catch return false;
        return mt == self.conf_mtime;
    }

    fn mapEntryUnchanged(map: *const FileMap, abs_path: []const u8) bool {
        const cached = map.get(abs_path) orelse return false;
        const mt = fileMtime(abs_path) catch return false;
        return mt == cached;
    }

    // ── Update ───────────────────────────────────────────────────────────────

    pub fn recordSource(self: *Cache, abs_path: []const u8) !void {
        try recordInMap(self.allocator, &self.sources, abs_path);
    }

    pub fn recordGuide(self: *Cache, abs_path: []const u8) !void {
        try recordInMap(self.allocator, &self.guides, abs_path);
    }

    pub fn recordConf(self: *Cache, abs_path: []const u8) !void {
        const mt = try fileMtime(abs_path);
        if (self.conf_path) |p| self.allocator.free(p);
        self.conf_path = try self.allocator.dupe(u8, abs_path);
        self.conf_mtime = mt;
    }

    fn recordInMap(allocator: std.mem.Allocator, map: *FileMap, abs_path: []const u8) !void {
        const mt = try fileMtime(abs_path);
        const res = try map.getOrPut(abs_path);
        if (!res.found_existing) {
            res.key_ptr.* = try allocator.dupe(u8, abs_path);
        }
        res.value_ptr.* = mt;
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Return the mtime of `path` in whole seconds since Unix epoch.
/// Uses `Dir.statFile` which avoids opening the file descriptor.
pub fn fileMtime(path: []const u8) !i64 {
    const stat = try std.fs.cwd().statFile(path);
    // stat.mtime is i128 nanoseconds; convert to i64 seconds.
    // Current timestamps (~1.74e9 s) are well within i64 range.
    return @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
}

/// Resolve `path` to an absolute path using `realpath`, falling back to a
/// simple `cwd + path` join if the file cannot be stat'd (should not happen
/// in normal use, but defensive).
pub fn absPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.realpathAlloc(allocator, path) catch {
        // Fallback: manual join of cwd + path.
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        return std.fs.path.resolve(allocator, &.{ cwd, path });
    };
}

fn jsonWriteStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"'  => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                try w.writeAll("\\u00");
                try w.writeByte(hex[c >> 4]);
                try w.writeByte(hex[c & 0xf]);
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}
