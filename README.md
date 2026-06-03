# snapcompose

Distribution of pre-baked, cache-warmed environment plugins for [rlock](https://github.com/pirj/rlock). Bake your project's environment once into a snapshot; serve it warm in under a second on every subsequent `rl new`.

Aimed at CI/PR workloads where:
- A clean isolated VM is created for every job (or for every untrusted PR), and
- Spending minutes per job re-installing Docker, Ruby gems, npm packages, or running migrations from scratch is wasteful.

## Plugins shipped

**Infrastructure**

- **`docker-engine`** — Installs Docker inside the Alpine guest. Single shared snapshot, reused across every project that activates Docker.
- **`docker-compose`** — Runs `docker compose up` against the project's compose file, waits for healthchecks, snapshots the warm state. Subsequent VMs from this snapshot have postgres / redis / app containers already running. Optional [`[docker-compose] file = "..."`](docs/snapcompose-toml.md#docker-compose) override and [`services = [...]`](docs/snapcompose-toml.md#services--) filter for projects that ship multiple compose files or want CI to bring up an infra-only subset.
- **`docker-registry-cache`** — Optional host-side registry mirror. Avoids docker.io rate limits and speeds up cold pulls.

**Runtimes** (one cache key per language — flipping a Python pin doesn't invalidate the Ruby layer)

- **`mise-base`** — Installs mise itself plus the build toolchain it needs to compile language runtimes from source.
- **`ruby-runtime`**, **`python-runtime`**, **`nodejs-runtime`**, **`go-runtime`**, **`rust-runtime`** — Per-language runtime installers driven by mise. Each reads its language's pin file (`.ruby-version`, `.python-version`, `.node-version`, …) so the cache key is exactly the runtime version it produced.

**Dependencies**

- **`ruby-bundler`** — `bundle install` against `Gemfile.lock`.
- **`npm`** — `npm ci` against `package-lock.json`.
- **`pnpm`** — `pnpm install --frozen-lockfile` against `pnpm-lock.yaml`.
- **`poetry`** — `poetry install` against `poetry.lock`.
- **`uv`** — `uv sync --frozen` against `uv.lock`.
- **`cargo`** — `cargo build` against `Cargo.lock`.

**Commands**

- **`snapc run -- <cmd>`** — Provision the VM (walking the chain) and execute the command. The CI workhorse.
- **`snapc auto-ci`** — Generate `snapcompose.toml` + a synthesised docker-compose from your existing `.github/workflows/*.yml` `services:` block + `setup-<lang>` actions. The frictionless-onboarding path for projects that already have a `services:`-based CI workflow.
- **`snapc pr <pr-url>`** — Sandbox an untrusted-fork PR (in progress).
- **`snapc cache`** — Cache management: `--gc`, `--push <oci-ref>`, `--pull <oci-ref>`.

**Deprecated**

- **`mise`** — The monolithic mise plugin is deprecated in favour of `mise-base` + per-language runtimes (one cache key per language vs. one shared key). Will be removed in v0.4. See [CHANGELOG.md](CHANGELOG.md).

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
| **monolith — Rails app + pg + redis** (Phase 2) | **828.34 s** ([run](https://github.com/pirj/snapcompose-benchmark/actions/runs/26765152927)) | **12.84 s** ([run](https://github.com/pirj/snapcompose-benchmark/actions/runs/26766024326)) — **64×** | **48.12 s** ([run](https://github.com/pirj/snapcompose-benchmark/actions/runs/26878173765)) — **17×**¹ |
| monolith — pg + redis only (Phase 1) | 143.17 s | 7.93 s — 18× | — |
| +1 microservice | — | — | — |
| +3 microservices | — | — | — |
| +5 microservices | — | — | — |

### gha-services (OSS Rails CI baseline)

The actual pattern ~77 % of OSS Rails projects use on GitHub Actions
([survey](https://github.com/pirj/meta/blob/main/research-2026-05-30-rails-oss-ci-survey.md)):
workflow YAML's `services:` keyword spins up pg + redis containers,
`ruby/setup-ruby` installs Ruby, `bundle install` then
`bin/rails db:create db:migrate test`. The test suite includes a
`HealthCheckTest` that exercises pg (via ActiveRecord) + redis
(via `Redis.ping`) so the timing reflects a real integration step,
not just provisioning.

This is the head-to-head comparison snapcompose's `monolith` row
is meant to beat. Cold = first run on a fresh CI runner. Warm =
`actions/cache` restored `vendor/bundle`. snapcompose's equivalent
runs the SAME `bin/rails db:create db:migrate test` command
inside the snapshot-restored VM — apples to apples.

|  | cold | warm |
|---|---|---|
| monolith — `services:` pg + redis + setup-ruby + bundle + rails test | — | — |

+1 / +3 / +5 rows omitted — those shapes are rare in OSS-on-GHA
and patterns vary too widely for a single canonical baseline.
Snapcompose's +N rows below are snapcompose-only numbers,
included to show how the layered snapshot cache behaves for
multi-service apps (the closed-source / private-monorepo case).

Phase 2 fixture: a Rails 8 app running natively in the VM via `mise + ruby-runtime + ruby-bundler` plugins, plus `docker-compose` for pg + redis service containers. The 828 s cold pays full compile-Ruby-from-source + bundle install + container start; the 12.8 s warm restores the entire live state — pg's shared buffers, Redis's working set, the Ruby/bundler trees, and the running containers — from a layered qcow2 snapshot.

¹ Phase 4 fixture: `[prebuild.fixture-marker]` live layer in `services/main` whose `key_files = [".snapcompose-bench-marker"]`. The workflow flips the marker between cold and warm-from-patch runs, forcing the leaf layer to rebuild while every ancestor in the chain (docker-engine, docker-compose, mise-base, ruby-runtime, ruby-bundler) restores warm. The 48 s wall-clock = 12 s warm-restore of ancestors + ~30 s rebuild + re-snapshot of the patched leaf. `patch_bytes=0` for this row because the Rails fixture's memory.bin exceeds 2 GiB, so aq v2.5.51's fallback to plain pzstd fires instead of `zstd --patch-from` — the storage win lands on smaller-VM fixtures and is the headline metric once `aq/ROADMAP.md §"QEMU-native zstd"` lands (or a future per-page delta scheme replaces the all-or-nothing patch-from).

Phase 1 fixture: pg + redis only, matching the dominant Rails CI `services:` pattern (77 % of OSS Rails projects per [`../meta/research-2026-05-30-rails-oss-ci-survey.md`](https://github.com/pirj/meta/blob/main/research-2026-05-30-rails-oss-ci-survey.md)).

**Baseline refactor 2026-06-03**: the previous `bench-docker.yml`
that measured `docker compose up -d --wait` against the pg+redis
infra stack only was deleted — wrong baseline for the outreach
pitch. The new `bench-gha-services.yml` mirrors what a real
maintainer sees when they look at their `ci.yml`: GHA `services:`
+ `setup-ruby` + `bundle install` + `bin/rails test`. The
snapcompose-side `bench-snapcompose.yml` monolith now runs the
same `rails test` command inside the snapshot-restored VM, so
the two numbers are directly comparable.

Cells marked `—` are pending the next bench run. The snapcompose
table's monolith cold / warm / warm-from-patch cells are filled
and reproduce across two iterations (12.12 s / 12.06 s for warm;
48.12 s / 47.54 s for warm-from-patch, < 2 % variance). +1 / +3
/ +5 cells iterate on the chain-reconstruction issue tracked in
`rlock/TODO.md`.

Phase 3's bench iteration surfaced **seven distinct concurrency bugs** on the multi-VM cold path, all fixed across the v3.1.7 stack:

| Bug | Surfaced in | Fix |
|---|---|---|
| `bootstrap_base_image` race (two concurrent ISO downloads) | `+1 par cold` | aq v2.5.45 — `flock` around `ensure_base_image` |
| Lockfile open mode (`9>` rejected by `set -fC` noclobber) | `+1 par cold` (post-v2.5.45) | aq v2.5.47 — switch to `9>>` append-open |
| Fixed 60 s incoming-migration poll budget overrun | `+1 seq cold` | aq v2.5.46/v2.5.48 — budget scales with staged memory size |
| `mise install node` needs Python on Alpine musl | `+1 par cold` (post-flock fix) | snapcompose v0.3.3 — `mise-base` adds `python3` |
| Concurrent `snapshot_save` qcow2 resize-lock contention | `+1 par cold` (post-aq fixes) | rlock v0.1.14 — `flock` around `snapshot_save` |
| Reader window during `rm -f` + `qemu-img convert` rewrite | `+1 par cold` (post-rlock flock) | rlock v0.1.15 — atomic-rename of every artefact |
| zstd `--patch-from` 2 GiB CLI single-shot ceiling | `warm-from-patch` save | aq v2.5.51 — fallback to plain pzstd when input > 2 GiB |

All cut into the bench fixture via [setup-snapcompose v3.1.7](https://github.com/pirj/setup-snapcompose/blob/main/CHANGELOG.md). Walking-skeleton fixtures for the +3 row (Python/FastAPI + Go/net-http) are in place; +5 row (Sinatra + Python-alt) is the deferred extension. The `aq` ROADMAP §"QEMU-native zstd" is parked IN WAITING on upstream QEMU 11.x — `multifd-compression=zstd` for `file:` URI is rejected on QEMU 10.0.3 / 11.0 as a documented architectural limit (mapped-ram requires seekable fd; compression uses non-seekable pipe), no fix in the 11.0 release.

## Tests

```sh
# From the snapcompose checkout, with rlock as a sibling directory:
bats test/
```

If rlock is elsewhere: `RL_FRAMEWORK_DIR=/path/to/rlock bats test/`.
