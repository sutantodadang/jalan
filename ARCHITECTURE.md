# Architecture

## Data flow

```
                 ┌──────────────────────────────────────────────┐
                 │                  frontends                    │
  config file →  │  gha · gitlab · jenkins · circleci · azure ·  │
                 │  bitbucket   (src/frontend/*.zig)             │
                 └───────────────────┬────────────────────────────┘
                                      │  lower to shared IR
                                      ▼
                          ┌───────────────────────┐
                          │   Pipeline IR          │
                          │   (src/ir.zig)         │
                          └───────────┬───────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                                     ▼
          ┌───────────────────┐                 ┌──────────────────────┐
          │  engine (scheduler) │                 │  translate.zig        │
          │  src/engine.zig     │                 │  IR → emitGha/         │
          │  DAG + parallel     │                 │  emitGitlab/...        │
          │  batches, expr eval │                 │  (topo-leveled stages) │
          └─────────┬──────────┘                 └──────────────────────┘
                    │  runStep/setupJob/teardownJob (vtable)
                    ▼
          ┌───────────────────┐
          │  backend           │
          │  native · docker ·  │
          │  nix                │
          └─────────┬──────────┘
                    │
      ┌─────────────┼─────────────────────┐
      ▼             ▼                     ▼
 snapshot store   step cache        TUI / debug
 (.jalan/store)   (src/cache.zig)   (src/tui.zig, src/debug.zig)
 time-travel,     content-          breakpoints, on-failure shell,
 --resume         addressed replay  full-screen step-through
```

Every frontend produces the same `ir.Pipeline`. The engine, backends,
snapshot store, cache, and TUI are all provider-agnostic: they only know
about the IR. `translate.zig` is the mirror image of a frontend: instead of
lowering a config into the IR, it renders the IR back out as another
provider's config.

## Module families

### IR (`src/ir.zig`)

The shared shape every frontend lowers into and every backend executes:
`Pipeline { name, source_path, jobs: []Job }`, `Job { id, display_name,
runs_on, needs, env, matrix, steps, container_image, services, provider,
manual }`, `Step { id, name, kind (run|uses), script, uses_ref, shell, env,
with, workdir, cond, continue_on_error, timeout_minutes, input_hash }`,
`Service { name, image, env }`. `ir.Provider` tags which frontend produced a
job (`github_actions`, `gitlab`, `jenkins`, `circleci`, `azure`,
`bitbucket`); the native backend and translate emitters both branch on it.
`ir.toJson` serializes a pipeline for `jalan lint --json`.

### Frontends (`src/frontend/*.zig`)

Each frontend parses its config format (via `src/yaml.zig`, except
Jenkins) into `ir.Pipeline`, collecting diagnostics into a `yaml.Diags` as
it goes. Every frontend follows the same shape: a `warn()` helper that
prefixes messages `"warning: "`, a `hasHardError()` check that fails the
whole parse if any diagnostic *isn't* a warning, and dependency-graph
validation (unknown `needs`, cycles) run after all jobs are lowered. See
[docs/providers.md](docs/providers.md) for exactly what each one simulates,
warns about, or rejects.

Jenkins is the odd one out: it has no YAML underneath. `src/frontend/jenkins.zig`
owns its own tokenizer and statement parser for the declarative
`pipeline { stages { ... } }` grammar. Scripted pipelines (`node { ... }`)
and declarative `script { }` blocks hand off to a separate Groovy pipeline:
`src/groovy/ast.zig` (lexer + parser for the CI-relevant Groovy subset:
GStrings, closures, command syntax; no classes, no `new`) feeds
`src/groovy/interp.zig` (a tree-walking interpreter with Groovy truthiness
and loop/range guards). The interpreter doesn't execute shell commands
itself. It calls back into `jenkins.zig`'s `hostCall`, which intercepts
`sh`/`bat`/`stage`/`node`/`parallel`/etc. and *collects* them as IR steps
and jobs rather than running them at parse time. `env.X = ...` assignments
inside scripted blocks are snapshotted per step so later steps see the
right value.

### Engine (`src/engine.zig`)

A Kahn-style topological scheduler over the `needs` DAG (cycles are
rejected upstream by the frontends). Jobs whose dependencies are all
resolved form a batch; batches run with up to `--max-parallel` (default 4)
jobs concurrently, each on its own `std.Thread` with a private
page-allocator-backed arena (caller arenas aren't thread-safe, so worker
results are copied back into the caller arena under a shared mutex before
the per-thread arena is torn down). If `std.Thread.spawn` fails (thread
limit exhausted), the engine falls back to running that job inline.

Within a job, steps run sequentially against an `expr.Env` that layers
global → job → matrix → step env (plus `secrets.*` and `needs.<job>.
outputs.<name>` from completed dependencies) so `${{ }}`/rules expressions
resolve the right value at each scope. `if: always()` steps are the one
exception to "skip everything after a failure": they still run so
cleanup/notification steps behave like real CI. A job whose `needs` include
a failed job is skipped, *except* when explicitly selected with `-j/--job`
(the CLI's job filter bypasses the failed-needs gate) or when the failed
prerequisite is itself a `manual` job left unselected (GitLab and Azure
treat unselected manual jobs like `allow_failure`, not a hard block).
`--on-failure` (`continue`/`stop`/`shell`) governs what happens the moment
a non-`continue-on-error` step fails: keep scheduling remaining
non-dependent work, halt the whole run, or drop into an interactive shell
in the failing step's environment.

### Backends (`src/backend.zig` + `src/backend/*.zig`)

A small vtable interface: `setupJob`, `runStep`, `teardownJob`, and the
optional `runContainerAction` (one-shot `docker://` GHA actions),
`openShell` (debugger drop-to-shell), and `cacheIdentity` (a string
identifying the effective runtime, used as part of the cache key).

- **native** (`backend/native.zig`) runs steps as real subprocesses. Shell
  resolution prefers `bash`/`sh` (including Git Bash) on Windows for every
  *non*-GitHub-Actions provider, because GitLab/Jenkins/CircleCI/Azure/
  Bitbucket scripts are written in POSIX shell (`$VAR`, `${VAR}`); pwsh
  would treat `$VAR` as its own (empty) variable. GHA jobs still default to
  pwsh/powershell/cmd on Windows, matching what `runs-on: windows-latest`
  actually gives you.
- **docker** (`backend/docker.zig`) creates one long-lived `sleep infinity`
  container per job (on the job's `container:` image, a config
  `image.<runs-on>=` mapping, or a bash/sh/python-capable default), runs
  each step by uploading its script as a tar archive and exec'ing it, and
  removes the container on teardown. Services get their own containers on a
  per-job Docker network, with a `waitForHealth` poll against
  `HEALTHCHECK` status (skips waiting if the image defines none, warns and
  continues after 60s if it never reports healthy, so a slow-starting service
  image doesn't fail the whole job).
- **nix** (`backend/nix.zig`) runs steps natively but intercepts
  `setup-node`/`setup-python`/`setup-go` GHA actions as Nix package
  installs instead of downloading a toolchain.

### Snapshot, cache, resume (`src/snap/*.zig`, `src/cache.zig`)

`src/snap/store.zig` is a content-addressed blob store under
`.jalan/store/`: file contents are sha256-addressed and fanned out into
`blobs/<hex[0..2]>/<hex>`, written atomically (temp file + rename), and
automatically deduplicated (same content, same address, write skipped).
`src/snap/runrecord.zig` writes one JSON record per run to
`.jalan/store/runs/<run-id>.json`: pipeline identity, per-step status and
snapshot path, and the flat `jobid.outputs.key` pairs the engine published.
It's rewritten after every completed job so a crashed run still resumes from
its last checkpoint. `jalan runs` reads these; `--resume <run-id> --at
<job/step>` restores the snapshot at that point and continues execution
from there.

`src/cache.zig` hashes a canonical string (backend, job image, step kind,
script/`uses_ref`, `with:` pairs, effective env, shell, workdir, and the
pre-step workspace tree hash) into a step cache key. A hit replays the
recorded stdout/stderr/exit code/outputs and materializes the files the
step wrote last time, without running the step's process again. Steps that
reference `secrets.*` (in script, `with:`, or `env:`) are excluded from
caching so secret values never land in the store.

### Translate (`src/translate.zig`)

`topoLevels` groups jobs into dependency levels (level 0 = no needs; level
N = every need resolved in an earlier level) for target formats that don't
have a native `needs:` graph (GitLab/Azure stages, Jenkins sequential
stages, Bitbucket's linear pipeline). Each target gets its own
`emitX(writer, pipeline)` function sharing one indent-tracking `Writer`.
Anything the target can't represent is kept as a `# jalan: ...` (or `//
jalan: ...` for Jenkins) note comment rather than dropped; see
[docs/providers.md](docs/providers.md#translate-emitters) for exactly what
each target preserves and what it notes. Round-trip (parse → emit →
re-parse) is exercised in `src/golden_test.zig`.

### YAML parser (`src/yaml.zig`)

An in-house subset, not a full YAML implementation: block mappings/
sequences (including a sequence dash at the same indentation as its parent
key), flow sequences, quoted scalars, and block scalars (`|` literal and
`>` folded, including comment-only interior lines). **YAML anchors and
aliases are not supported.** Encountering one is a hard diagnostic
("YAML anchors are not supported"), not a silent no-op.

### Expression evaluators

Three separate, deliberately small evaluators, one per provider that needs
one:

- **GitHub Actions** `${{ }}` (`src/expr.zig`). Dot-path lookups, string/
  number/bool/null literals, `==`/`!=`/`&&`/`\|\|`/unary `!`, and
  `contains`/`startsWith`/`endsWith`/`format`/`always()`.
- **GitLab CI `rules:`** (`evalRuleIf` in `src/frontend/gitlab.zig`). Its
  own tiny parser: `$VAR` references, string/regex literals, `==`/`!=`/
  `=~`/`!~` (regex always treated as matching, with a warning) /`&&`/`\|\|`.
- **Groovy** (`src/groovy/ast.zig` + `interp.zig`, described above under
  Frontends).

None of the three share code; each is scoped to exactly what its provider's
`if:`/`rules:`/scripted-pipeline syntax needs.

## Design principles

- **Zero dependencies.** `build.zig.zon` declares no external packages.
  Everything (YAML parsing, HTTP-over-Unix-socket for Docker, the Groovy
  interpreter) is implemented in this repo.
- **Arena-only memory.** Every CLI invocation runs inside one
  `std.heap.ArenaAllocator`; nothing is individually freed, because the
  process lifetime *is* the arena lifetime. The one exception is the
  engine's parallel worker threads, which each get their own
  page-allocator-backed arena (a caller arena isn't safe to share across
  threads) and copy only their final result back into the caller arena
  under a mutex before their own arena is torn down.
- **Warn, don't block, but never silently.** Every frontend's unsupported
  feature either gets simulated, gets a `warning: ...` diagnostic and is
  safely ignored/approximated, or, if the config is actually malformed,
  fails the whole parse. There is no fourth option where something is
  quietly dropped without a trace. See [docs/providers.md](docs/providers.md)
  for the exact per-provider breakdown.
- **Local-first.** Anything that depends on the real CI provider's server
  (variable groups, artifact storage, remote caches, deployment approval
  gates) is out of scope by design, not an oversight; it's warned about,
  and the pipeline still runs the parts that make sense locally.

## Zig 0.15.2 gotchas for contributors

- **Result-location aliasing.** A pattern like `x = .{ ... someFn(x) ... }`
  where `someFn` reads `x` while it's also the destination of the
  assignment can corrupt state under 0.15.2's result-location semantics;
  this has bitten the engine's step-result construction before. Use a
  temporary variable instead of assigning into the same binding you're
  still reading from mid-expression.
- **`ArrayList` is unmanaged-by-default and starts as `.empty`.** The
  pattern throughout this codebase is `var list: std.ArrayList(T) = .empty;`
  followed by `try list.append(alloc, item)`; the allocator is passed at
  the call site, not stored on the list. Don't reach for `.init(alloc)`;
  it isn't the 0.15.2 shape used here.
- **Never call `cli.runMain`/`cli.main` from a `test { }` block.** They
  write directly to the real process stdout. Under `zig build test`'s
  `--listen=-` IPC protocol, stdout *is* the test-result channel; calling
  them from a test corrupts the protocol and aborts the entire test binary
  instead of failing one test. Test the pure logic underneath
  (`lintMain`/`translateMain`/`parseRunArgs`/`anyJobRan`/...) instead, which
  take an output buffer or return a value rather than writing to stdout.
