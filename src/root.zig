//! jalan — local CI simulator. Module root: public API + test registry.
pub const yaml = @import("yaml.zig");
pub const ir = @import("ir.zig");
pub const expr = @import("expr.zig");
pub const gha = @import("frontend/gha.zig");
pub const native = @import("backend/native.zig");

test {
    _ = yaml;
    _ = ir;
    _ = expr;
    _ = gha;
    _ = native;
}
