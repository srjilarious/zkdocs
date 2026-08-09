//! Fixture for testing that internal link schemes inside `///` doc comments
//! get resolved. See RenderSiteTests.docCommentSymLinkIsResolved in
//! tests/main.zig.

/// See [bar](sym:bar) for a related function.
pub fn foo() void {}

/// A related function.
pub fn bar() void {}
