# CLI reference

```
jalan lint [file] [--json] [--strict] [--backend <name>]
jalan run [file] [-j <job>] [--step <id>] [--dry-run] [--env K=V]...
          [--secret-file <path>] [--matrix k=v]... [--max-parallel N]
          [--strict] [--no-color] [--backend <name>] [--pull]
          [--snapshot|--no-snapshot] [--cache|--no-cache]
          [--break <job/step>]... [--on-failure shell|stop|continue]
          [--resume <run-id> --at <job/step>]
jalan debug [file] [same options as jalan run]
jalan translate [file] --to <provider> [-o <path>]
          (providers: gha, gitlab, jenkins, circleci, azure, bitbucket)
jalan runs [--json]
jalan version
jalan help
```

This is the literal output of `jalan help`. Everything below documents each
command against the actual flag parser in `src/cli.zig`.

## Commands

### `jalan lint [file]`

Parses the config into the internal Pipeline IR and reports diagnostics.
Never executes anything.

| Flag | Meaning |
|---|---|
| `[file]` | Path to a CI config. If omitted, resolved via [workflow discovery](#workflow-discovery-order). |
| `--json` | Emit the parsed pipeline as JSON instead of the human-readable job list. |
| `--strict` | Exit 2 if any diagnostics (including warnings) were produced. |
| `--backend <name>` | Parsed and validated (`native`, `docker`, `podman`, `nix`, `auto`), but has no effect on lint itself; it exists for flag-parity with `run`. |

Without `--json`, output is:

```
workflow: <pipeline name>
job: <display name> (needs: <comma-separated needs>)
```

With `--json`, output is the pipeline serialized via `ir.toJson` (name,
source_path, jobs with id/display_name/runs_on/needs/matrix/env/steps).

### `jalan run [file]`

Parses, then executes the pipeline.

| Flag | Type / default | Meaning |
|---|---|---|
| `[file]` | positional | Config path. Falls back to workflow discovery, or to the recorded workflow of `--resume`'s run. |
| `-j, --job <name>` | string | Only run this job. Its `needs` are intentionally not run and do not block it. Selecting a manual job with `-j` is how manual jobs execute. |
| `--step <id>` | string | Only run steps matching this id, across selected jobs. |
| `--dry-run` | flag | Resolve the plan without executing steps. |
| `--env K=V` | repeatable | Extra env applied to every step. |
| `--secret-file <path>` | string | Load `K=V` secrets from this file instead of the default `.jalan/secrets.env`. |
| `--matrix k=v` | repeatable | Filter matrix-expanded jobs to combinations matching every pair given. |
| `--max-parallel N` | usize, default `4` | Max jobs run concurrently within a scheduling batch. |
| `--strict` | flag | Exit 2 if the parse produced any diagnostics. |
| `--no-color` | flag | Disable ANSI color in the summary (also respects the `NO_COLOR` env var). |
| `--backend <name>` | string, default `auto` | `native`, `docker`, `podman`, `nix`, or `auto` (Docker if reachable, else native). Overrides `.jalan/config`'s `backend=`. |
| `--pull` | flag | Force a fresh image pull (Docker/podman backends). |
| `--snapshot` / `--no-snapshot` | tri-state, default from `.jalan/config` (`true` if unset) | Record every step's workspace state for time-travel/resume. |
| `--cache` / `--no-cache` | tri-state, default from `.jalan/config` (`false` if unset) | Replay unchanged steps from the content-addressed cache. |
| `--break <job/step>` | repeatable | Breakpoint selector. `step` may be a step id or a zero-based index. Requires the `job/step` shape (exactly one `/`). |
| `--on-failure shell\|stop\|continue` | string, default `continue` | What to do when a step fails: drop to an interactive shell, stop the run, or keep going per normal `continue-on-error`/DAG semantics. |
| `--resume <run-id> --at <job/step>` | pair, both or neither | Restore workspace state from a prior snapshot and resume execution from that job/step. |

`--resume` and `--at` must be given together; giving one without the other
is a usage error (exit 2).

### `jalan debug [file]`

Same flags as `jalan run`, plus it always runs with the full-screen TUI
(`src/tui.zig`) and forces `--break`-style step-through of every step.
Requires an interactive stdin and stdout. If the terminal isn't
interactive, it errors immediately (exit 2) and suggests `jalan run` or
`jalan runs` instead.

### `jalan translate [file] --to <provider>`

Parses `file` (or the discovered default workflow) and re-emits it as
another provider's config.

| Flag | Meaning |
|---|---|
| `--to <provider>` | Required. One of `gha` (aliases `github`, `github-actions`), `gitlab`, `jenkins`, `circleci`, `azure` (alias `azure-pipelines`), `bitbucket`. |
| `-o, --output <path>` | Write the emitted config to this path instead of stdout. Prints `wrote <path>` on success. |

Diagnostics from parsing the source config are printed before the emitted
output (or before the "wrote" line, if `-o` is used). Anything the target
provider can't represent is kept but marked with a `# jalan: ...` note
comment (`// jalan: ...` for the Jenkinsfile/Groovy target) rather than
silently dropped; see [docs/providers.md](providers.md#translate-emitters)
for what each target does and doesn't preserve.

### `jalan runs [--json]`

Lists recorded runs from `.jalan/store` (populated when `--snapshot` is on,
which is the default).

Table output:

```
RUN ID	STARTED	BACKEND	WORKFLOW	JOBS
<run-id>	<unix-seconds>	<backend>	<workflow-path>	<job>=<status>,...
```

`--json` emits an array of run records instead. An empty store prints
`no recorded runs` (or `[]` for JSON), not an error.

### `jalan version`

Prints `jalan 0.1.0`.

### `jalan help` / `jalan --help` / no arguments

Prints the usage block at the top of this document.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | The pipeline ran but at least one job failed (`run`/`debug` only). |
| `2` | Usage error: bad/unknown flags, unknown command, provider could not be detected, config failed to parse, no job/step matched a filter, invalid `--resume` target, or `--strict` found diagnostics. |
| `3` | Internal or I/O error: file not readable/writable, workspace path unresolvable, chosen backend unavailable (Docker/podman socket unreachable, Nix not on `PATH`), resume snapshot restore failed, or an uncaught internal error. |

## Provider auto-detection

`detectProvider` (in `src/cli.zig`) checks, in this order:

1. **Filename/path match**: `.gitlab-ci.yml`/`.gitlab-ci.yaml` → GitLab;
   `Jenkinsfile*`/`*.jenkinsfile` → Jenkins; `azure-pipelines.*` or
   `.azure-pipelines.*` → Azure; `bitbucket-pipelines.*` → Bitbucket; a path
   containing `.circleci/` → CircleCI; a path containing
   `.github/workflows` → GitHub Actions.
2. **Content sniff**, only if no path/filename matched, checked in this
   order (CircleCI/Azure configs can also contain `jobs:` + `steps:`, so
   their more distinctive sniffs run first):
   - a root-level `pipelines:` key → Bitbucket
   - `vmImage`, a root-level `pool:` key, or a `- task:` entry → Azure
   - root-level `workflows:` **and** `version:` → CircleCI
   - `jobs:` plus either `runs-on` or `steps:` → GitHub Actions
   - `pipeline {` / `pipeline{` or `node {` / `node{` → Jenkins
3. Otherwise: `unknown`, which every command reports as
   `error: could not detect CI provider` (exit 2).

A "root-level key" match requires the key to start at column 0 of some line
(`hasRootKey`), so nested keys of the same name don't cause false positives.

## Workflow discovery order

When no file is given, `findDefaultWorkflow` looks for, in order:

1. `.github/workflows/*.yml`/`*.yaml`, lexicographically smallest name
   (iterated directory listing, sorted).
2. `.gitlab-ci.yml`
3. `.gitlab-ci.yaml`
4. `Jenkinsfile`
5. `.circleci/config.yml`
6. `azure-pipelines.yml`
7. `bitbucket-pipelines.yml`

If none exist, the command prints `error: no workflow found (...)` and
exits 2.

## Environment and state

- **`.jalan/config`**: plain `key=value` lines, `#` comments, blank lines
  ignored. Keys: `backend` (default `auto`), `docker.socket`,
  `nix.packages` (comma-separated), `image.<runs-on-label>=<image>` (one
  entry per line, repeatable), `snapshot` (bool, default `true`), `cache`
  (bool, default `false`). An explicit non-`auto` CLI `--backend` always
  wins over this file; a non-`auto` config value wins over the `auto`
  default.
- **`.jalan/secrets.env`**: default secrets file for `jalan run`/`debug`
  when `--secret-file` isn't given. Same `K=V` format as `.jalan/config`
  (comments and blank lines skipped). Values become available to steps as
  `secrets.<NAME>` in the expression environment (what GitHub Actions'
  `${{ secrets.NAME }}` reads) and are masked as `***` wherever jalan logs
  effective env. Steps that reference `secrets.*` are excluded from the
  step cache.
- **`.jalan/store/`**: content-addressed blob store for snapshots
  (`blobs/<hex[0..2]>/<hex>`, sha256-addressed, deduplicated automatically)
  and run records (`runs/<run-id>.json`), used by `jalan runs` and
  `--resume`.

## Notes

- `--no-color` and the `NO_COLOR` environment variable both disable ANSI
  color in the `run`/`debug` summary; either is sufficient.
- Docker/podman `--backend` requires a reachable socket
  (`\\.\pipe\docker_engine` on Windows, `/var/run/docker.sock` on
  Unix, or `.jalan/config`'s `docker.socket=`); podman also tries
  `$XDG_RUNTIME_DIR/podman/podman.sock` and `/run/podman/podman.sock`.
  `--backend nix` requires `nix` on `PATH` (WSL2 on Windows).
