# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.1.0 - 2026-08-03

### Added

- Core MVP: GitHub Actions frontend, shared Pipeline IR, native-shell
  backend, DAG scheduling engine, and `jalan lint`/`jalan run` CLI.
- Docker backend with per-job containers, service containers with health
  checks, and full `uses:` support (JS actions, composite actions,
  `docker://` container actions).
- Debug suite: content-addressed workspace snapshots, time-travel resume
  (`jalan runs`, `--resume <run-id> --at <job/step>`), the step cache
  (`--cache`), and drop-to-shell on failure (`--on-failure shell`).
- Full-screen TUI debugger (`jalan debug`).
- GitLab CI frontend: `extends`/templates, `default:`, a local `rules:`/
  `when:`/`workflow:` expression evaluator, `include: local`, and
  `parallel:matrix`.
- Jenkins declarative pipeline frontend (own tokenizer and parser, no
  Groovy evaluation for declarative-only Jenkinsfiles).
- In-repo Groovy interpreter (no JVM) powering Jenkins scripted pipelines
  and declarative `script { }` blocks.
- CircleCI, Azure Pipelines, and Bitbucket Pipelines frontends.
- Cross-provider translation (`jalan translate <file> --to <provider>`):
  six emitters over the shared IR, with lossy parts marked by `# jalan:`
  note comments instead of being dropped.
