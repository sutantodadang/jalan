//! jalan — local CI simulator. Module root: public API + test registry.
pub const yaml = @import("yaml.zig");
pub const ir = @import("ir.zig");
pub const expr = @import("expr.zig");
pub const gha = @import("frontend/gha.zig");
pub const native = @import("backend/native.zig");
pub const backend = @import("backend.zig");
pub const engine = @import("engine.zig");
pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const docker_http = @import("docker/http.zig");
pub const docker_client = @import("docker/client.zig");
pub const docker_backend = @import("backend/docker.zig");
pub const nix_backend = @import("backend/nix.zig");
pub const actions_resolve = @import("actions/resolve.zig");
pub const actions_runner = @import("actions/runner.zig");
pub const snap_store = @import("snap/store.zig");

test {
    _ = yaml;
    _ = ir;
    _ = expr;
    _ = gha;
    _ = native;
    _ = backend;
    _ = engine;
    _ = cli;
    _ = config;
    _ = docker_http;
    _ = docker_client;
    _ = docker_backend;
    _ = nix_backend;
    _ = actions_resolve;
    _ = actions_runner;
    _ = snap_store;
    _ = @import("golden_test.zig");
}
