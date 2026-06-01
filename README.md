# snapcompose

Distribution of pre-baked, cache-warmed environment plugins for [rlock](https://github.com/pirj/rlock). Bake your project's environment once into a snapshot; serve it warm in under a second on every subsequent `rl new`.

Aimed at CI/PR workloads where:
- A clean isolated VM is created for every job (or for every untrusted PR), and
- Spending minutes per job re-installing Docker, Ruby gems, npm packages, or running migrations from scratch is wasteful.

## Plugins shipped

- **`docker-engine`** — Installs Docker inside the Alpine guest. Single shared snapshot, reused across every project that activates Docker.
- **`docker-compose`** — Runs `docker compose up` against the project's compose file, waits for healthchecks, snapshots the warm state. Subsequent VMs from this snapshot have postgres / redis / app containers already running.

Planned (see `docs/superpowers/plans/`):

- `mise`, `nvm` — language runtime managers
- `ruby-bundler`, `npm`, `uv`, `pnpm`, `poetry` — dependency installers
- `rails-db-migrations`, `rails-db-seeds`, `rails-load-db-schema` — Rails lifecycle
- `snapc run` — one-shot CI job runner
- `snapc pr` — PR-from-untrusted-fork sandbox runner

## Install

snapcompose is a plugin pack: it provides plugins for the rlock framework. Clone both side by side, then add both `bin/` dirs to `PATH`:

```sh
git clone git@github.com:pirj/rlock.git
git clone git@github.com:pirj/snapcompose.git
export PATH="$PWD/rlock/bin:$PWD/snapcompose/bin:$PATH"
export RLOCK_PLUGIN_PATH="$PWD/snapcompose/plugins"

cd your-project   # has Dockerfile / docker-compose.yml
rl new            # provisions the VM, walking the cache chain
bake run -- rake test
```

`bake` is a thin wrapper around `rl bake-<sub>` for the friendlier UX:

| Friendly form           | Equivalent                              |
|-------------------------|-----------------------------------------|
| `snapc run -- <cmd>`     | `rl snapc-run -- <cmd>`                  |
| `snapc pr --cmd '<cmd>' <pr-url>` | `rl snapc-pr --cmd '<cmd>' <pr-url>` |
| `snapc cache`            | `rl snapc-cache`                         |
| `snapc cache --rm <plugin>` | `rl snapc-cache --rm <plugin>`         |

For full Docker functionality, `aq` (the underlying VM engine) needs enough RAM. The current `aq -m 1G` default is too tight for most compose stacks. Roadmap item: `aq --memory=NG` flag, after which snapcompose plugins can declare `kind = "live"` for sub-second restore. Until then, expect cold restarts on warm-layer cache hits.

## Design

snapcompose is one of several plugin packs that consume the rlock framework. Architecture is documented in:

- [`rlock/docs/superpowers/specs/2026-05-11-layered-snapshots-design.md`](https://github.com/pirj/rlock/blob/main/docs/superpowers/specs/2026-05-11-layered-snapshots-design.md) — layered qcow2 snapshot orchestration, plugin protocol, cached/incremental/ephemeral strategies.
- [`rlock/docs/superpowers/specs/2026-05-18-snapshot-kind-design.md`](https://github.com/pirj/rlock/blob/main/docs/superpowers/specs/2026-05-18-snapshot-kind-design.md) — cold-vs-live snapshot tradeoff.
- [`rlock/docs/superpowers/plans/2026-05-11-repo-split-migration.md`](https://github.com/pirj/rlock/blob/main/docs/superpowers/plans/2026-05-11-repo-split-migration.md) — why we have three repos.

## Benchmark

Cold provisioning timings from the [`snapcompose-benchmark`](https://github.com/pirj/snapcompose-benchmark) fixture, run on a GitHub Actions `ubuntu-latest` runner. Triggered manually before each performance-related release.

Methodology: [`docs/bench/2026-05-29-microservices-benchmark.md`](docs/bench/2026-05-29-microservices-benchmark.md). Workflow: [`bench-snapcompose.yml`](https://github.com/pirj/snapcompose-benchmark/blob/main/.github/workflows/bench-snapcompose.yml).

### snapcompose

|  | cold | warm | warm-from-patch |
|---|---|---|---|
| **monolith — Rails app + pg + redis** (Phase 2) | **828.34 s** ([run](https://github.com/pirj/snapcompose-benchmark/actions/runs/26765152927)) | **12.84 s** ([run](https://github.com/pirj/snapcompose-benchmark/actions/runs/26766024326)) — **64×** | — |
| monolith — pg + redis only (Phase 1) | 143.17 s | 7.93 s — 18× | — |
| +1 microservice | — | — | — |
| +3 microservices | — | — | — |
| +5 microservices | — | — | — |

### docker (baseline)

|  | cold | warm | warm-from-patch |
|---|---|---|---|
| monolith | — | — | — |
| +1 microservice | — | — | — |
| +3 microservices | — | — | — |
| +5 microservices | — | — | — |

Phase 2 fixture: a Rails 8 app running natively in the VM via `mise + ruby-runtime + ruby-bundler` plugins, plus `docker-compose` for pg + redis service containers. The 828 s cold pays full compile-Ruby-from-source + bundle install + container start; the 12.8 s warm restores the entire live state — pg's shared buffers, Redis's working set, the Ruby/bundler trees, and the running containers — from a layered qcow2 snapshot.

Phase 1 fixture: pg + redis only, matching the dominant Rails CI `services:` pattern (77 % of OSS Rails projects per [`../meta/research-2026-05-30-rails-oss-ci-survey.md`](https://github.com/pirj/meta/blob/main/research-2026-05-30-rails-oss-ci-survey.md)).

Cells marked `—` are pending — Phases 3–6 add warm-from-patch, parallel/sequential, the five microservices, and the docker baseline.

## Tests

```sh
# From the snapcompose checkout, with rlock as a sibling directory:
bats test/
```

If rlock is elsewhere: `RL_FRAMEWORK_DIR=/path/to/rlock bats test/`.
