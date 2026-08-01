//! Fixture for testing extraction of a module with a missing import.
//! See ImportTests.missingImportReturnsErrorNotCrash in tests/main.zig.

const missing = @import("./does_not_exist.zig");

pub fn use() void {
    _ = missing;
}
