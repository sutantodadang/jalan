# Provider support matrix

For every provider, jalan splits config features into three buckets:

- **Simulated**: parsed and actually executed/enforced.
- **Warned & skipped**: recognized, produces a `warning: ...` diagnostic,
  parsing still succeeds and the pipeline still runs; the feature itself is
  ignored, approximated, or run in a way that differs from the real CI
  provider (see the note).
- **Errors**: malformed structure. Produces a non-`warning:` diagnostic,
  which fails the whole parse (`error.ParseFailed`, exit 2). The pipeline
  does not run at all.

This is a hard rule in every frontend (`hasHardError` in each
`src/frontend/*.zig`): if any diagnostic isn't prefixed `warning: `, the
parse fails outright. Nothing partially-broken silently runs.

## GitHub Actions (`.github/workflows/*.yml`)

| Simulated | Warned & skipped | Errors |
|---|---|---|
| `name`, `on`, `env`, `defaults`, `jobs` (workflow); `name`, `runs-on`, `needs`, `env`, `steps`, `strategy`, `defaults`, `container`, `services` (job); `name`, `id`, `run`, `uses`, `shell`, `env`, `if`, `working-directory`, `continue-on-error`, `timeout-minutes` (step); matrix expansion; `${{ }}` expressions; `needs.*.outputs.*` | `permissions`, `concurrency`, `run-name` (workflow); `if`, `outputs`, `continue-on-error`, `timeout-minutes`, `environment`, `concurrency`, `permissions` (job level; recognized GHA keys, not simulated at job level); any other unrecognized key at any level; `timeout-minutes` is recorded but not enforced (no actual timeout); unknown `shell:` value falls back to the platform default; `x-jalan-nix-packages` (removed; use `uses: actions/setup-node\|setup-python\|setup-go` instead) | Services with no `image`; job depends on an unknown job; duplicate step id within a job; dependency cycle; job has no `steps`; invalid `${{ }}` expression in `if:`; missing `jobs:` key; `jobs:` not a mapping |

Notes:

- Step `run:`/`uses:` (including JS, composite, and `docker://` actions),
  job-level `container:` and `services:` (with health-wait), and matrix
  expansion are fully simulated, not just parsed.
- Supported `${{ }}` expression grammar (`src/expr.zig`): dot-path context
  lookups (`github.ref`, `env.X`, `matrix.X`, `needs.<job>.outputs.<name>`,
  `secrets.X`, ...), string/number/bool/null literals, `==`, `!=`, `&&`,
  `\|\|`, unary `!`, and functions `contains(a, b)`, `startsWith(a, b)`,
  `endsWith(a, b)`, `format(tmpl, ...)`, `always()`. An unknown path
  evaluates to null (falsy); no other GHA built-in functions
  (`success()`, `failure()`, `hashFiles()`, ...) are implemented.

## GitLab CI (`.gitlab-ci.yml`)

| Simulated | Warned & skipped | Errors |
|---|---|---|
| `script`, `stage`, `needs`, `variables`, `before_script`, `image`, `services`, `parallel` (with a matrix), `allow_failure` (boolean), `extends`, `after_script`, `rules`, `when` | `artifacts`, `cache`, `dependencies`, `only`/`except`, `tags`, `interruptible`, `timeout`, `retry`, `resource_group`, `trigger`, `coverage`, `release`, `environment` (job keys; parsed, execution-neutral, ignored); numeric `parallel:` without a matrix (runs once); `changes`/`exists` rule keys (not evaluated); non-boolean `allow_failure`; `=~`/`!~` regex rules (treated as matching); delayed `when: delayed` (runs immediately); `when: manual`/`when: never` jobs excluded with a warning explaining why; unresolvable rule expressions (treated as matching); multiple service aliases; `include:` types `file`/`project`/`remote`/`template`/`component` and wildcard includes | Job has no `script` (or an empty one); `extends` cycle or unknown target; job needs an unknown job; job references an unknown stage; dependency cycle; `stages:` empty; pipeline not a mapping; no jobs |

Notes:

- **Rules expression subset** (`evalRuleIf` in `src/frontend/gitlab.zig`):
  string/quoted-string literals, `$VARIABLE` references (resolved from
  job/global `variables:`), `null`, `==`, `!=`, `&&`, `\|\|`, parens, and
  `/regex/` literals. `=~`/`!~` against a regex are **always treated as a
  match** with a one-time warning per rules block; jalan does not run a
  regex engine against CI variables. An expression that fails to parse (or
  has leftover input) is also treated as matching, with a warning quoting
  the expression.
- `rules:` fully replaces `only`/`except`/`when` evaluation for a job when
  present (`when:` alongside `rules:` is warned and ignored).

## Jenkins (`Jenkinsfile`)

Both declarative (`pipeline { ... }`) and scripted (`node { ... }`)
Jenkinsfiles are supported. Scripted blocks are lowered by an in-repo Groovy
interpreter (`src/groovy/`); no JVM involved.

| Simulated | Warned & skipped | Errors |
|---|---|---|
| `agent` label (used as `runs-on`), `stages`/`stage`, `steps`, `sh`/`bat`/`powershell`/`script`, `environment`, `parallel` stages, sequential stage dependencies, scripted `node`/`stage`/`parallel` via the Groovy interpreter | `agent` options other than a label (docker/dockerfile agents; runs on native instead); `credentials()` (variable left unset); other `x()` credential-style calls; step arguments jalan doesn't model (ignored); `dir` nesting beyond one level; malformed `withEnv` entries; `checkout` (not needed locally, skipped); unsupported steps (skipped, inner steps of wrapper steps like `timeout`/`retry` still run); `input` gates (stage runs without waiting); `when` conditions (stage always runs; evaluated once, then a warning notes it isn't re-checked); nested `parallel`; `post` blocks (`always`/`success`/`failure`/...); nested `node` blocks (inner runs in the same context); duplicate stage names (renamed) | Unterminated block comment/string literal/`script` block; unexpected character or token; expected statement/value; Jenkinsfile isn't a single declarative `pipeline` block (for the declarative parser); a stage with no name or no steps; a stage with both `parallel` and `steps`; pipeline has no stages; scripted pipeline produces no steps |

Notes:

- **Groovy subset** (`src/groovy/ast.zig` + `interp.zig`): literals
  (null/bool/int/float/string/GStrings with `${}` interpolation), lists,
  maps, ranges, ternary/elvis, arithmetic/relational/logical operators,
  `in`, `<<`, indexing, field/method access on strings/lists/maps, closures,
  `if`/`for`/`while`, and a small built-in method set (`contains`,
  `startsWith`, `endsWith`, `replace`, `split`, `tokenize`, `toInteger`,
  list `each`/`collect`/`find`/`findAll`/`add`/`join`, map
  `containsKey`/`get`/`put`/`each`). There are **no classes and no `new`**:
  the grammar simply doesn't parse them. Loops are capped at 1,000,000
  iterations (`loop_guard_max`) and ranges at a fixed size cap; exceeding
  either is a hard interpreter error. `stage`/`node`/`parallel` calls are
  rejected inside `script { }` blocks (declarative pipelines only, to keep
  scripted structure out of declarative stages). `sh(..., returnStdout:
  true)` style calls are recognized by the interpreter's call dispatch.

## CircleCI (`.circleci/config.yml`)

| Simulated | Warned & skipped | Errors |
|---|---|---|
| `docker`/`machine`/`macos`/`executor` (docker images run in-container; machine/macos run natively with a warning), `environment`, `working_directory`, `steps`, `run`/`checkout`(no-op)/nested steps, `workflows`/`requires`, only the **first** workflow | Non-docker executors (`machine`/`macos`) run natively, not simulated as a VM; `parallelism`, `resource_class` (not simulated); `store_artifacts`, `store_test_results`, `persist_to_workspace`, `attach_workspace`, `save_cache`, `restore_cache`, `setup_remote_docker`, `add_ssh_keys` (skipped); unrecognized `run:` keys; `<< >>` templating (left literal, not evaluated); `orbs` (jobs using orb steps will fail to parse those steps); `parameters` at top level; reusable `commands:` (invocation not expanded); additional `workflows:` beyond the first (ignored) | Docker/executor entry missing `image`/`name`; unknown named executor; job has no `steps`; workflow references an unknown job; config has no `jobs`; root not a mapping |

Notes:

- Only the **first** `workflows:` entry is simulated; every other workflow
  is ignored with a warning naming it.
- `<< pipeline.parameters.x >>`-style templating is recognized structurally
  but left as literal text; no parameter substitution happens.

## Azure Pipelines (`azure-pipelines.yml`)

| Simulated | Warned & skipped | Errors |
|---|---|---|
| `stages`/`jobs`/`steps` (any nesting level), `dependsOn`, `variables`, `pool`/`vmImage` (native execution), `strategy.matrix`, `script`/`bash`/`pwsh`/`powershell` steps, `$(VAR)` macro rewriting | `trigger`, `pr`, `schedules`, `resources`, `parameters` (accepted at root, not used locally); variable groups (not available locally); `templates:` (skipped); predefined dotted variables like `$(Build.SourcesDirectory)` (left literal; no Azure agent context to resolve them); unsupported task steps, `publish`/`download` (skipped); `condition:` on steps/jobs (not evaluated; always runs); `failOnStderr`, `retryCountOnTaskFailure`, `timeoutInMinutes`, `continueOnError` (jobs), `workspace`, `services` (job-level, not simulated); `strategy.maxParallel`; deployment jobs (run as normal jobs) | Job depends on an unknown job/stage; job has no `steps`; stage has no `jobs`; unresolvable job/stage/step structure; root not a mapping; no `stages`/`jobs`/`steps` at all; dependency cycle |

Notes:

- **`$(VAR)` macro rewriting**: `rewriteMacros` in `src/frontend/azure.zig`
  rewrites `$(NAME)` in step scripts before storing them: `${NAME}` for
  bash/sh/no explicit shell, `$env:NAME` for `pwsh`/`powershell`. Names
  containing a dot (`Build.SourcesDirectory`, `System.X`, ...) are Azure's
  own predefined variables; jalan leaves those literal with a warning
  rather than inventing a fake value.
- Deployment jobs are treated as ordinary jobs (the deploy-strategy wrapper
  around them is not simulated).

## Bitbucket Pipelines (`bitbucket-pipelines.yml`)

| Simulated | Warned & skipped | Errors |
|---|---|---|
| `image`, `pipelines.default` (or the first non-default pipeline if there's no default), `step`/`parallel`/`stage` items, `script`/`after-script`, `variables`, `services` (from `definitions.services`) | `deployment`, `size`, `max-time`, `clone`, `oidc` (step keys; ignored); custom `caches`; `definitions` keys other than `services`; the built-in `docker` service (not simulated); `artifacts` transfer; step `condition`; `fail-fast` on `parallel`; `trigger: manual` (not enforced; runs anyway); custom pipeline variables (not available locally); `options`; root-level `clone`; any pipeline section other than the one chosen to simulate | `step`/`stage`/`parallel` entries that aren't proper mappings; a `step`/`stage` with no `script`/`steps`; unknown named service reference; no `pipelines:` defined; pipeline has no jobs; root not a mapping |

Notes:

- Bitbucket supports several named pipeline sections (`default`,
  branch/tag/pull-request selectors, custom). jalan picks **one** to run:
  `default` if present, otherwise the first pipeline it finds; every other
  section is warned as "not simulated".
- `trigger: manual` is recognized but not enforced; jalan runs the step
  regardless, since there's no interactive "run this manually" concept in a
  one-shot local run.

## Translate emitters

`jalan translate <file> --to <provider>` re-emits the parsed Pipeline IR as
another provider's format (`src/translate.zig`, `emitGha`/`emitGitlab`/
`emitJenkins`/`emitCircleci`/`emitAzure`/`emitBitbucket`). Every emitted
file starts with a header comment (`# jalan: translated from <path>`, or
`// jalan: translated from <path>` for Jenkinsfiles). Anything the target
can't represent is kept as a note comment next to the affected job/step
instead of being silently dropped:

| Target | What's emitted | What gets a `# jalan:` / `// jalan:` note |
|---|---|---|
| GitHub Actions | `jobs:`/`steps:` mirroring the IR directly (GHA is the IR's closest native shape) | Manual jobs run as normal jobs (source was manual) |
| GitLab CI | `stages:`, one job per IR job with `script:` | Manual jobs run as normal (source was manual); dropped service env vars; skipped `uses:` actions (no GitLab equivalent; replaced with an `echo` placeholder); jobs with no script steps get a placeholder script |
| Jenkins | A declarative `pipeline { stages { ... } }` | Manual jobs (source was manual); skipped `uses:` actions |
| CircleCI | `jobs:`/`workflows:` | Manual jobs need `type: approval` in real CircleCI (not simulated here); skipped `uses:` actions; `continue-on-error` (CircleCI has no per-step allow-fail); `cmd` shell (no CircleCI equivalent, omitted) |
| Azure Pipelines | `stages:`/`jobs:`/`steps:` | Dropped job services; manual jobs run as normal; skipped `uses:` actions; `cmd` shell (emitted as a plain script, no dedicated Azure step) |
| Bitbucket Pipelines | A single `pipelines: default:` pipeline | Dependency edges approximated as sequential stages (Bitbucket has no `needs:` graph); job env exported via a shell `export` line; `continue-on-error` (no per-step allow-fail in Bitbucket); step workdir folded into the script; skipped `uses:` actions; jobs with no script steps get a placeholder |

Translation is round-trip tested (parse → emit → re-parse) for the paths
covered in `src/golden_test.zig`, but translation is inherently lossy across
providers with different feature sets; read the emitted note comments
before trusting the output as-is.
