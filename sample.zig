//! Sample module for testing zkdocs parsing.
//! This module demonstrates the kinds of declarations that zkdocs should extract.

const std = @import("std");
const math = @import("./math.zig");

/// Adds two integers together.
/// Returns the sum of `a` and `b`.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// Subtracts `b` from `a`.
pub fn sub(a: i32, b: i32) i32 {
    return a - b;
}

fn privateHelper() void {}

/// A 2D point in integer space.
pub const Point = struct {
    /// The x coordinate.
    x: i32,
    /// The y coordinate.
    y: i32,

    /// Returns a point at the origin.
    pub fn zero() Point {
        return .{ .x = 0, .y = 0 };
    }

    /// Translates this point by the given delta.
    pub fn translate(self: Point, dx: i32, dy: i32) Point {
        return .{ .x = self.x + dx, .y = self.y + dy };
    }
};

/// Primary colors available in the palette.
pub const Color = enum {
    red,
    green,
    blue,
};

/// Log levels for the application logger.
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

/// Errors returned by bounds-checked operations.
pub const Error = error{
    /// Index was outside the valid range.
    OutOfBounds,
    /// Input value failed validation.
    InvalidInput,
};

/// Returns the element at `idx`, or an inferred error if the lookup fails.
pub fn maybeGet(idx: usize) !i32 {
    if (idx > 10) return error.OutOfBounds;
    return @intCast(idx);
}

/// Looks up `idx`, returning one of `Error`'s named variants on failure.
pub fn checkedGet(idx: usize) Error!i32 {
    if (idx > 10) return error.OutOfBounds;
    return @intCast(idx);
}

/// Divides `a` by `b`, listing its own error set inline.
pub fn strictDivide(a: i32, b: i32) error{ DivByZero, Overflow }!i32 {
    if (b == 0) return error.DivByZero;
    return @divTrunc(a, b);
}

/// The default buffer size used by readers.
pub const default_buf_size: usize = 4096;

/// A version string exported to consumers.
pub const version: []const u8 = "0.1.0";

/// Wraps a value together with an error tag.
pub const Wrapper = struct {
    /// The wrapped value.
    value: i64,
    /// Whether the value is valid.
    valid: bool,

    /// Errors that can occur constructing a Wrapper.
    pub const ConstructError = error{
        /// The supplied value was negative.
        Negative,
    };

    /// Constructs a valid wrapper.
    pub fn ok(v: i64) Wrapper {
        return .{ .value = v, .valid = true };
    }

    /// Constructs an invalid wrapper.
    pub fn err() Wrapper {
        return .{ .value = 0, .valid = false };
    }
};

/// Proxy to the math sub-module's `multiply` function.
pub fn multiply(a: i64, b: i64) i64 {
    return math.multiply(a, b);
}

/// A generic stack that holds items of type `T`.
pub fn Stack(comptime T: type) type {
    return struct {
        /// The backing storage.
        items: []T,
        /// Current number of elements.
        len: usize,

        /// Push an item onto the stack.
        pub fn push(self: *@This(), item: T) void { _ = self; _ = item; }

        /// Pop and return the top item, or null if empty.
        pub fn pop(self: *@This()) ?T { _ = self; return null; }

        /// Peek at the top item without removing it.
        pub fn peek(self: *const @This()) ?T { _ = self; return null; }
    };
}

/// Returns the first `n` items of a slice whose element type is only known
/// at compile time. Only `T` is comptime here, so this can still be called
/// with runtime `items`/`n`.
pub fn firstN(comptime T: type, items: []const T, n: usize) []const T {
    return items[0..n];
}

/// Rounds `@sizeOf(T)` up to `alignment`. Every parameter is comptime, so
/// this can only ever be called in a comptime context.
pub fn sizeOfPadded(comptime T: type, comptime alignment: usize) usize {
    return std.mem.alignForward(usize, @sizeOf(T), alignment);
}

// Sanity-checks the module's default buffer size at compile time. Zig
// doesn't allow a `///` doc comment directly above a bare `comptime {}`
// block (a plain `//` comment like this one is the most a block like this
// can carry), so this fixture only exercises comptime-block extraction
// itself -- the accompanying-doc-comment case is covered by a synthetic
// source string in error_sets_tests.zig's sibling, comptime_extern_tests.zig.
comptime {
    if (default_buf_size == 0) @compileError("default_buf_size must be non-zero");
}

/// Declares (but does not implement) a C function this module can call.
pub extern "c" fn c_abs(x: i32) callconv(.c) i32;

/// Exposes `add` under a C-compatible calling convention and symbol name.
pub export fn addExported(a: i32, b: i32) callconv(.c) i32 {
    return add(a, b);
}

/// A C-compatible point layout, safe to pass across the FFI boundary.
pub const ExternPoint = extern struct {
    x: i32,
    y: i32,
};

/// A tightly packed pair of boolean flags.
pub const PackedFlags = packed struct {
    a: bool,
    b: bool,
};

/// A type with sequential code fences in its doc comment.
///
/// First example:
/// ```zig
/// const x = 1;
/// ```
///
/// Second example:
/// ```zig
/// const y = 2;
/// ```
pub const SequentialFenceExample = struct {};
