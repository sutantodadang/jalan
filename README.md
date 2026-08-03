# jalan

*jalan* (Indonesian for "run" or "road"). A local CI simulator: parse your
pipeline config, run it on your machine, and debug it like a real program.

[![CI](https://img.shields.io/github/actions/workflow/status/sutantodadang/jalan/ci.yml?branch=main&label=CI)](https://github.com/sutantodadang/jalan/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/sponsor-GitHub%20Sponsors-ea4aaa.svg)](https://github.com/sponsors/sutantodadang)

## Why

Push, wait three minutes, read a log, fix a typo, push again. That loop is
how most people debug CI. jalan runs the same pipeline on your own machine
in seconds, so you find the broken step before it ever reaches the runner.

It reads GitHub Actions, GitLab CI, Jenkins, CircleCI, Azure Pipelines, and
Bitbucket Pipelines configs directly, with no conversion step and no second
file to maintain. When something fails, drop into a shell inside the failing step,
rewind to any earlier step with time-travel snapshots, or set a breakpoint
and step through the run.

## Features

- **Six providers**: GitHub Actions, GitLab CI, Jenkins (declarative and
  scripted), CircleCI, Azure Pipelines, Bitbucket Pipelines. Auto-detected
  from the file name, path, or content.
- **Two backends**: native host shells (bash, sh, pwsh, powershell, cmd,
  python) or Docker containers with per-job networks and service health
  checks. `--backend auto` picks Docker when it's reachable, native
  otherwise.
- **Real DAG scheduler**: parallel jobs, matrix expansion, `needs.*.outputs.*`
  across jobs, `if:` conditions, `continue-on-error`, manual jobs.
- **Time-travel debugging**: snapshot every step, list past runs, resume any
  run from any job/step, set breakpoints, drop to a shell on failure.
- **Content-addressed step cache**: unchanged steps replay their last result
  instead of re-running. Secrets are never cached.
- **Translate between providers**: turn an Azure pipeline into a GitLab
  pipeline, a GitHub workflow into a Jenkinsfile, and so on. Lossy parts are
  marked with `# jalan:` comments instead of silently dropped.
- **Jenkins scripted pipelines run without a JVM.** jalan ships its own
  Groovy interpreter (`src/groovy/`) for the CI-relevant subset of the
  language.
- **Zero runtime dependencies.** One static binary. Zig 0.15.2, arena memory
  model, no GC, no VM, no network calls unless you asked for Docker.

## Quick start

```sh
git clone https://github.com/sutantodadang/jalan.git
cd jalan
zig build
```

The binary lands at `zig-out/bin/jalan`. From any repo with a supported CI
config:

```sh
jalan lint                 # parse + validate, no execution
jalan run --dry-run        # show what would run, without running it
jalan run                  # actually run it, backend auto-detected
```

`jalan` picks up `.github/workflows/*.yml`, `.gitlab-ci.yml`, `Jenkinsfile`,
`.circleci/config.yml`, `azure-pipelines.yml`, or `bitbucket-pipelines.yml`
automatically. Pass a path explicitly to override detection:
`jalan run path/to/config.yml`.

## Supported providers

| Provider | Config file | Notes |
|---|---|---|
| GitHub Actions | `.github/workflows/*.yml` | `run:`/`uses:` steps, JS/composite/docker actions, matrix, `${{ }}` expressions, services |
| GitLab CI | `.gitlab-ci.yml` | `extends`, `default`, `rules`/`when`/`workflow` evaluated locally, `include: local`, `parallel:matrix` |
| Jenkins | `Jenkinsfile` | Declarative and scripted (in-repo Groovy interpreter, no JVM) |
| CircleCI | `.circleci/config.yml` | Docker executors, `workflows`/`requires`, first workflow simulated |
| Azure Pipelines | `azure-pipelines.yml` | Stages/jobs/steps, `strategy.matrix`, `$(VAR)` macro rewriting |
| Bitbucket Pipelines | `bitbucket-pipelines.yml` | Default pipeline, `parallel`, `after-script`, services |

Full per-key support matrix (simulated / warned-and-skipped / hard error):
[docs/providers.md](docs/providers.md).

## Usage

### Running

```sh
jalan run                                  # default workflow, auto backend
jalan run -j build                         # only the "build" job (its needs are skipped)
jalan run --step compile                   # only steps matching this id
jalan run --env NODE_ENV=test              # extra env for every step
jalan run --matrix os=ubuntu-latest        # filter matrix jobs
jalan run --backend docker --pull          # force Docker, pull fresh images
jalan run --max-parallel 8                 # cap concurrent jobs (default 4)
```

### Debugging

```sh
jalan run --snapshot                       # (default on) record every step
jalan runs                                 # list past runs
jalan run --resume <run-id> --at build/compile   # rewind and re-run from there
jalan run --break build/compile --on-failure shell  # stop, or drop to a shell
jalan debug                                # full-screen TUI debugger (interactive terminals only)
```

### Caching

```sh
jalan run --cache                          # replay unchanged steps instead of re-running them
```

Cache keys hash the backend, image, script, `with:`/env/shell/workdir, and
the pre-step workspace tree. Steps that reference `secrets.*` are never
cached.

### Translating between providers

```sh
$ jalan translate azure-pipelines.yml --to gitlab
azure-pipelines.yml:1:1: warning: 'trigger' is not simulated (ignored)
# jalan: translated from azure-pipelines.yml
stages:
  - s1

job:
  stage: s1
  variables:
    NODE_ENV: test
  script:
    - "echo \"installing\""
    - "echo \"testing ${NODE_ENV}\""
```

Anything that doesn't map cleanly to the target provider is kept but marked
with a `# jalan:` (or `// jalan:` for Jenkinsfiles) note comment, never
silently dropped.

Full command and flag reference: [docs/cli.md](docs/cli.md).
Architecture and module layout: [ARCHITECTURE.md](ARCHITECTURE.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, test conventions, and
the checklist for adding a new provider frontend.

## License

jalan is licensed under the [GNU AGPL-3.0](LICENSE). Commercial licensing
(for use that AGPL's terms don't fit) is available on request; contact the
author. If jalan saves you a CI loop, consider
[sponsoring the project](https://github.com/sponsors/sutantodadang).
