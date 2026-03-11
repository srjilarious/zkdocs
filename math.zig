//! Basic math utilities for testing @import following.

/// Multiplies two 64-bit integers.
pub fn multiply(a: i64, b: i64) i64 {
    return a * b;
}

/// Divides `a` by `b`.
/// Caller must ensure `b != 0`.
pub fn divide(a: i64, b: i64) i64 {
    return @divTrunc(a, b);
}

/// Clamps `value` to the range [`lo`, `hi`].
pub fn clamp(value: i64, lo: i64, hi: i64) i64 {
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

/// Integer vector operations.
pub const Vec2 = struct {
    x: i64,
    y: i64,

    /// Dot product of two vectors.
    pub fn dot(a: Vec2, b: Vec2) i64 {
        return a.x * b.x + a.y * b.y;
    }
};
