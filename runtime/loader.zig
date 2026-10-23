// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

/// A provider source is an absolute path or a system-library name.
pub const LoadSource = union(enum) {
    /// Absolute path; relative paths return `InvalidSource`.
    path: []const u8,
    /// Basename or SONAME; separators and NUL return `InvalidSource`.
    system: []const u8,
};

/// Errors returned when a provider cannot be loaded.
pub const LoadError = error{
    /// Empty path or system name.
    EmptySource,
    /// Request exceeds `max_source_len`; it is never truncated.
    SourceTooLong,
    /// Invalid path or system name, or a request containing NUL.
    InvalidSource,
    /// This target has no dynamic loader.
    UnsupportedTarget,
    /// The platform loader refused the request.
    OpenFailed,
    /// The opened provider does not export a required symbol.
    MissingSymbol,
    /// Provider validation declined the candidate.
    ValidationFailed,
    /// A different provider is already loading or loaded.
    ProviderMismatch,
    /// The loading thread called `load` recursively.
    ReentrantLoad,
};

/// Maximum retained provider-source length, in bytes.
pub const max_source_len = 32768;

/// Stores the exact request bytes without allocation.
const SourceRecord = struct {
    tag: enum(u8) { none = 0, path, system } = .none,
    len: u32 = 0,
    bytes: [max_source_len]u8 = undefined,

    /// Called under the loader lock after length validation.
    fn set(self: *SourceRecord, request: LoadSource) void {
        const text = switch (request) {
            .path => |p| p,
            .system => |s| s,
        };
        @memcpy(self.bytes[0..text.len], text);
        self.len = @intCast(text.len);
        self.tag = switch (request) {
            .path => .path,
            .system => .system,
        };
    }

    /// Returns the retained request, or null before a request is stored.
    pub fn source(self: *const SourceRecord) ?LoadSource {
        const text = self.bytes[0..self.len];
        return switch (self.tag) {
            .none => null,
            .path => .{ .path = text },
            .system => .{ .system = text },
        };
    }
};

/// Compares request kind and bytes without path normalization.
pub fn eqlSource(a: LoadSource, b: LoadSource) bool {
    return switch (a) {
        .path => |pa| switch (b) {
            .path => |pb| std.mem.eql(u8, pa, pb),
            .system => false,
        },
        .system => |sa| switch (b) {
            .system => |sb| std.mem.eql(u8, sa, sb),
            .path => false,
        },
    };
}

fn validateSource(source: LoadSource) LoadError!void {
    const text = switch (source) {
        .path => |p| p,
        .system => |s| s,
    };
    if (text.len == 0) return error.EmptySource;
    if (text.len > max_source_len) return error.SourceTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSource;
    switch (source) {
        .path => {
            const absolute = if (builtin.target.os.tag == .windows)
                switch (std.Io.Dir.path.getWin32PathType(u8, text)) {
                    .drive_absolute, .unc_absolute, .local_device, .root_local_device => true,
                    .relative, .rooted, .drive_relative => false,
                }
            else
                std.Io.Dir.path.isAbsolutePosix(text);
            if (!absolute) return error.InvalidSource;
        },
        .system => {
            for (text) |byte| {
                if (std.Io.Dir.path.isSep(byte)) return error.InvalidSource;
                if (builtin.target.os.tag == .windows and byte == ':') return error.InvalidSource;
            }
        },
    }
}

/// State of one configured module's dispatch table.
pub const Phase = enum(u8) {
    /// No active load; a failed attempt can be retried explicitly.
    not_loaded = 0,
    /// A load attempt is in progress.
    loading = 1,
    /// The table is published.
    ready = 2,
};

/// Release-published readiness flag for routed calls.
/// Acquire reads observe table writes made before publication.
pub const Ready = struct {
    phase: std.atomic.Value(u8) = .init(@backingInt(Phase.not_loaded)),

    /// Returns whether the table has been published.
    pub fn isReady(self: *const Ready) bool {
        return self.phase.load(.acquire) == @backingInt(Phase.ready);
    }

    /// Returns the current load phase.
    pub fn state(self: *const Ready) Phase {
        return @fromBackingInt(@intCast(self.phase.load(.acquire)));
    }

    /// Stores a phase with release ordering.
    pub fn set(self: *Ready, value: Phase) void {
        self.phase.store(@backingInt(value), .release);
    }
};

/// Type of exported symbol stored in the dispatch table.
pub const SymbolKind = enum {
    /// Function pointer with the translated signature.
    function,
    /// Provider-owned object address; the table stores no copy.
    data,
};

/// One required provider export and its kind.
pub const Symbol = struct {
    /// Exported name, as declared by the C header.
    name: [:0]const u8,
    /// Function or data symbol.
    kind: SymbolKind,
};

/// Panics with the library and symbol if a routed call precedes load.
pub fn panicNotReady(library: []const u8, comptime symbol: []const u8) noreturn {
    std.debug.panic(
        "{s}: {s} was called before this module was loaded; call " ++
            "load({{ .path = \"...\" }}) or load({{ .system = \"...\" }}) first",
        .{ library, symbol },
    );
}

/// False on targets without loader APIs (WASI, Emscripten, freestanding).
pub const supported_target: bool = switch (builtin.target.os.tag) {
    .wasi, .emscripten, .freestanding => false,
    else => true,
};

/// Loader state for one configured dispatch.
/// Failed attempts retry; same-source calls coalesce, while other sources return `ProviderMismatch`.
pub fn Loader(comptime Config: type) type {
    return struct {
        const LoaderType = @This();

        /// Table type supplied by the configuration.
        pub const table_type = Config.table;

        /// Active or draining attempt; each configured module has its own record.
        attempt: ?Attempt = null,

        /// Exact source copy; immutable after publication and lock-protected before it.
        request: SourceRecord = .{},

        /// Loads a provider; concurrent same-source callers share one attempt.
        /// Failed attempts can retry; a different source returns `ProviderMismatch`.
        pub fn load(self: *LoaderType, source: LoadSource) LoadError!void {
            try validateSource(source);
            // The acquire fast path accepts a matching request without locking.
            if (Config.ready().isReady()) return self.accept(source);

            Config.sync.lock();
            while (true) {
                switch (Config.ready().state()) {
                    .ready => {
                        Config.sync.unlock();
                        return self.accept(source);
                    },
                    .loading => {
                        const attempt = &self.attempt.?;
                        if (attempt.owner == Config.sync.threadSelf()) {
                            Config.sync.unlock();
                            return error.ReentrantLoad;
                        }
                        if (!eqlSource(self.request.source().?, source)) {
                            Config.sync.unlock();
                            return error.ProviderMismatch;
                        }
                        // Join the existing attempt instead of starting another.
                        attempt.waiters += 1;
                        while (Config.ready().state() == .loading) Config.sync.wait();
                        const result = attempt.result;
                        attempt.waiters -= 1;
                        // Keep the attempt record until every waiter consumes its result.
                        Config.sync.broadcast();
                        Config.sync.unlock();
                        return result;
                    },
                    .not_loaded => {
                        // Wait for failed-attempt waiters to drain before retrying.
                        if (self.attempt != null) {
                            Config.sync.wait();
                            continue;
                        }
                        break;
                    },
                }
            }

            self.request.set(source);
            self.attempt = .{ .owner = Config.sync.threadSelf() };
            Config.ready().set(.loading);
            Config.sync.unlock();

            // Run platform loading unlocked; callers wait on the attempt, not the lock.
            // Provider constructors must not wait on another call joining this attempt.
            const outcome = runAttempt(self.request.source().?);
            const succeeded = if (outcome) |_| true else |_| false;

            Config.sync.lock();
            self.attempt.?.result = outcome;
            Config.ready().set(if (succeeded) .ready else .not_loaded);
            // Wake every waiter after publishing the attempt result.
            Config.sync.broadcast();
            // Retain the record until all waiters drain.
            while (self.attempt.?.waiters > 0) Config.sync.wait();
            self.attempt = null;
            // Wake retry callers after clearing the attempt.
            Config.sync.broadcast();
            Config.sync.unlock();

            return outcome;
        }

        /// Returns the successful request, or null before a successful load.
        pub fn loadedSource(self: *const LoaderType) ?LoadSource {
            if (!Config.ready().isReady()) return null;
            return self.request.source();
        }

            // Called only after the readiness acquire load.
        fn accept(self: *const LoaderType, source: LoadSource) LoadError!void {
            const published = self.request.source() orelse unreachable;
            if (eqlSource(published, source)) return;
            return error.ProviderMismatch;
        }

        /// Opens and validates a candidate without publishing it.
        fn runAttempt(source: LoadSource) LoadError!void {
            const handle = platform.open(source) catch |err| return err;

            var retain = false;
            defer if (!retain) platform.close(handle);

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |_, index| {
                    Config.assignMissing(index, Config.tablePtr());
                }
            }

            inline for (Config.symbols, 0..) |symbol, index| {
                const address = platform.lookup(handle, symbol.name) orelse
                    return error.MissingSymbol;
                Config.assign(index, Config.tablePtr(), address);
            }

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |symbol, index| {
                    if (platform.lookup(handle, symbol.name)) |address| {
                        Config.assignOptional(index, Config.tablePtr(), address);
                    }
                }
            }

            if (@hasDecl(Config, "validate")) {
                if (Config.validate(Config.tablePtr())) |refusal| {
                    // The loader prints this static refusal string.
                    std.debug.print("{s}: refusing this provider: {s}\n", .{
                        Config.library_name,
                        refusal,
                    });
                    return error.ValidationFailed;
                }
            }

            // Keep the handle open: published table pointers refer to it.
            retain = true;
        }
    };
}

/// Load result and waiters shared until the attempt drains.
const Attempt = struct {
    /// Thread running the attempt; used to detect reentrant loads.
    owner: u64,
    /// Written before leaving `.loading` and read by attached waiters afterwards.
    result: LoadError!void = error.OpenFailed,
    /// Keeps the attempt record alive until every waiter consumes its result.
    waiters: usize = 0,
};

/// Windows path-conversion buffer for the 32767-unit limit and terminator.
const windows_path_units = 32768;

const platform = if (builtin.target.os.tag == .windows)
    Windows
else if (supported_target)
    Unix
else
    NoLoader;

/// Backend for targets without dynamic loading.
const NoLoader = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        _ = source;
        return error.UnsupportedTarget;
    }
    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        _ = handle;
        _ = name;
        return null;
    }
    fn close(handle: *anyopaque) void {
        _ = handle;
    }
};

/// Unix `dlopen`/`dlsym` backend.
const Unix = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        var buffer: [max_source_len + 1]u8 = undefined;
        @memcpy(buffer[0..text.len], text);
        buffer[text.len] = 0;
        // Resolve dependencies at open time; keep provider symbols local.
        return std.c.dlopen(
            // `dlopen` requires a sentinel-terminated path.
            buffer[0..text.len :0].ptr,
            .{ .NOW = true, .GLOBAL = false },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return std.c.dlsym(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = std.c.dlclose(handle);
    }
};

const kernel32 = struct {
    extern "kernel32" fn LoadLibraryExW(
        file_name: [*:0]const u16,
        file: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
};

/// Windows `LoadLibraryExW`/`GetProcAddress` backend.
const Windows = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget, SourceTooLong };

    /// Search standard directories and, for explicit paths, the DLL directory.
    /// The current working directory is not searched.
    const load_library_search_default_dirs: u32 = 0x0000_1000;
    const load_library_search_dll_load_dir: u32 = 0x0000_0100;

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        if (text.len > windows_path_units) return error.SourceTooLong;
        var buffer: [windows_path_units + 1]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(buffer[0..text.len], text) catch
            return error.OpenFailed;
        buffer[units] = 0;
        return kernel32.LoadLibraryExW(
            buffer[0..units :0],
            null,
            load_library_search_default_dirs | switch (source) {
                .path => load_library_search_dll_load_dir,
                .system => @as(u32, 0),
            },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return kernel32.GetProcAddress(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = kernel32.FreeLibrary(handle);
    }
};
