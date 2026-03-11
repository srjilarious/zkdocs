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

/// A generic result type.
pub const Error = error{
    OutOfBounds,
    InvalidInput,
};

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
