//! Sample module for testing zkdocs parsing.

/// Adds two numbers together.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// A simple struct.
pub const Point = struct {
    x: i32,
    y: i32,
};

fn privateFn() void {}
