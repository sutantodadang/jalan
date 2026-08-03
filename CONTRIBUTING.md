# Contributing

## Dev setup

Requires Zig **0.15.2** (see `build.zig.zon`'s `minimum_zig_version`).

```sh
git clone https://github.com/sutantodadang/jalan.git
cd jalan
zig build                       # binary at zig-out/bin/jalan
zig build test --summary all    # 376 tests, a handful skipped without a live Docker daemon
```

`jalan` has zero external dependencies: `zig build`/`zig build test` are
the whole toolchain, no `zig fetch` step needed.

## Test conventions

- Tests live **in the file they test**, as `test "description" { ... }`
  blocks at the bottom of the module; there's no separate `tests/`
  directory. Look at the bottom of any `src/*.zig` or `src/frontend/*.zig`
  file for the pattern to follow.
- Every test that allocates uses the arena pattern:

  ```zig
  test "..." {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      // ...
  }
  ```

- **Never call `cli.runMain` or `cli.main` from a test.** They write
  directly to the real process stdout, and `zig build test`'s
  `--listen=-` IPC protocol uses stdout as its result channel; calling
  them from a test corrupts the protocol and aborts the whole test binary
  instead of failing one test. Test the pure logic underneath instead:
  `lintMain`/`translateMain` take an output buffer and return a status
  code; `parseRunArgs`/`parseLintArgs`/`anyJobRan`/`anyStepRan` etc. are
  plain functions. See the comment above the `anyJobRan`/`anyStepRan` tests
  in `src/cli.zig` for the fuller rationale.
- New modules must be registered in `src/root.zig`'s `test { ... }` block
  (`_ = your_module;`) or `zig build test` won't run their tests at all.

## Adding a new provider frontend

`src/frontend/gitlab.zig` is the best reference implementation to mirror:
it has the full pattern: key-allowlist warnings, a `rules:`-style
expression evaluator, `extends`/template merging, and dependency-graph
validation. Checklist:

1. **New file**: `src/frontend/<provider>.zig`, exposing
   `pub fn parsePipeline(alloc, path, source, diags: *yaml.Diags) !ir.Pipeline`
   (match the existing frontends' signature so `cli.parseProvider`'s
   `switch` stays uniform). Use `yaml.zig` to parse unless the format isn't
   YAML (Jenkins is the exception: its own tokenizer lives in the same
   file).
2. **`ir.Provider`**: add a new enum member in `src/ir.zig` and set it on
   every `ir.Job` your frontend produces. The native backend's shell
   resolution and the translate emitters both branch on this.
3. **`src/cli.zig` wiring**:
   - `Provider` enum (the CLI's own, separate from `ir.Provider`) gets a
     new tag.
   - `detectProvider` gets a filename/path check and, if the format is
     ambiguous with existing sniffs, a content sniff (check the comment
     above the existing sniffs for the ordering rule: distinctive sniffs
     must run before the loose GHA `jobs:`+`steps:` fallback).
   - `parseProvider`'s `switch` gets a new arm calling your
     `parsePipeline`.
   - `findDefaultWorkflow` gets a candidate path/glob, in whatever priority
     order makes sense relative to the existing providers.
4. **Native shell preference**: decide whether your provider's scripts are
   POSIX shell (`$VAR`) or something else. Every existing non-GHA provider
   defaults to bash/sh on Windows (see `defaultShellForProvider` in
   `src/backend/native.zig`) because their scripts assume POSIX expansion.
   Only override this if your provider's real CI actually defaults to
   something else on Windows.
5. **`src/root.zig`**: add `pub const <provider> = @import("frontend/<provider>.zig");`
   and `_ = <provider>;` in the `test { }` block.
6. **Translate emitter (optional but expected)**: add an `emitX` function
   to `src/translate.zig` and a `Target` enum member so other providers can
   translate *into* yours, and so your own frontend's output can round-trip
   through the golden tests in `src/golden_test.zig`.
7. **Diagnostics discipline**: every unsupported-but-well-formed feature
   gets a `warning: ...`-prefixed diagnostic and the pipeline keeps
   running; every genuinely malformed structure gets a non-prefixed
   diagnostic, which fails the whole parse (`hasHardError`; copy the
   pattern from any existing frontend). Never drop a feature silently.
8. **Docs**: add your provider's row to the table in `README.md`'s
   "Supported providers" section and a support-matrix section to
   `docs/providers.md` once the feature set stabilizes.

## PR expectations

- `zig build test --summary all` passes (Docker/Nix-dependent tests may
  legitimately skip without a live daemon; that's fine, a regression in
  the non-skipped count is not).
- Smoke-test your change against a real fixture, not just unit tests:
  `zig-out/bin/jalan run <your-config>` (or `lint`/`translate`) end to end.
  `testdata/workflows/` and `testdata/actions/` have existing fixtures to
  extend or copy the shape of.
- Keep diagnostics wording consistent with the existing "warning: ..." /
  hard-error split described above; a reviewer will check for it.

## License

Contributions are accepted under the project's license,
[AGPL-3.0](LICENSE). By submitting a PR you agree your contribution is
licensed under the same terms.
