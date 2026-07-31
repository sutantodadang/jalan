//! jalan — local CI simulator. Module root: public API + test registry.
pub const yaml = @import("yaml.zig");
pub const ir = @import("ir.zig");

test {
    _ = yaml;
    _ = ir;
}
