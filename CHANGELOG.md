# Changelog

All notable changes to snapcompose — one-liner per change.

## 2026-05-27 — Renamed from bakeri.sh

**BREAKING CHANGE.** Repo + tool + config-file rename:
- Repo: `pirj/bakeri.sh` → `pirj/snapcompose` (GitHub redirects
  preserve old URLs, but git remotes need to be updated).
- CLI command: `bake` → `snapc`. `bake run -- pytest` becomes
  `snapc run -- pytest`. Subcommands: `snapc run`, `snapc cache`,
  `snapc pr`.
- Config file: `bakerish.toml` → `snapcompose.toml`. Clean break,
  no alias — old file is no longer read.
- Synth dir: `.bakerish/plugins/` → `.snapcompose/plugins/`.
- OCI media type: `application/vnd.bakerish.layer.v1+gzip` →
  `application/vnd.snapcompose.layer.v1+gzip` (and the
  `.cache.v1+json` artifact type follows the same pattern).
  Previously pushed caches use the old media type and won't be
  recognised after this version.
- Env vars: `BAKERI_LIB` → `SNAPC_LIB`, `BAKE_PROFILE` → `SNAPC_PROFILE`.
- Internal git refs: `refs/heads/_bake_run` → `refs/heads/_snapc_run`,
  `refs/heads/_bake_pr` → `refs/heads/_snapc_pr`.
- Plugin directory names: `plugins/bake-{run,cache,pr}/` →
  `plugins/snapc-{run,cache,pr}/`.

Companion repos to bump in lockstep:
- `pirj/setup-bakerish` → `pirj/setup-snapcompose` (separate commit, version bumped to v3).
- Project fixtures under `pirj/bakerish-rails-pg-example` → `pirj/snapcompose-rails-pg-example`.

## Unreleased

## v0.3.3 — 2026-06-02 — mise-base installs python3 (Node source-build fix)

`mise install node` on Alpine compiles from source because the
official nodejs.org binaries are glibc-only and Alpine is musl.
The source build runs `./configure` which invokes `python` — not
shipped in Alpine's `build-base` and not previously installed by
`mise-base`. Surfaced by snapcompose-benchmark Phase 3 walking-
skeleton on 2026-06-02 (run 26807611414 / `+1 par cold`):
`mise ERROR sh failed: ./configure: exec: line 8: python: not
found`.

mise-base now installs `python3` alongside its other build deps.
Bumps the plugin's snapshot_key from `mise-base-v1` to
`mise-base-v2` so cached chain layers from older mise-base
contents (no python3) get rebuilt; existing `setup-snapcompose`
caches under the same `cache-key-prefix` will hit one cold pass
to rebuild the mise-base layer then go warm.

## Unreleased

- **`mise` plugin deprecated; will be removed in v0.4.** Replace
  `plugins = [..., "mise", ...]` with `plugins = [..., "mise-base",
  "<lang>-runtime", ...]` (or use the `ruby` shortcut shipped in
  v0.3.0, which expands to `mise-base + ruby-runtime + ruby-bundler`).
  Old `snapcompose.toml` files without an explicit `plugins = [...]`
  still trigger the monolithic mise plugin via `.ruby-version` /
  `.tool-versions` / etc., so the deprecation is non-breaking at
  v0.3. v0.4 will drop the trigger list and the plugin shell;
  remove it from any explicit `plugins = [...]` arrays before
  bumping. Rationale: a single mise layer mixes Ruby + Node +
  Python + Go + Rust into one cache key, so changing the Python
  pin invalidates the Ruby layer too. The per-language split keys
  each language independently. See
  [`plugins/mise-base/plugin.toml`](plugins/mise-base/plugin.toml)
  +
  [`plugins/{ruby,python,nodejs,go,rust}-runtime/plugin.toml`](plugins/).
- **CI**: `.github/workflows/ci.yml` runs the bats suite (125
  tests, ~seconds wall-clock) on push/PR. Pure-bash unit tests
  against plugin.toml + lib functions — no VM boots, no qemu, no
  kvm. Sibling rlock checkout pinned to v0.1.3.

## v0.1.2 — 2026-05-23

- **`[disk] size`** in `snapcompose.toml` now overrides rlock's
  default `--size=16G`. Mirrors the `[memory] size` pattern: `bake
  run` reads the field via `toml_get_in_section` and threads it
  through as `rl new --size=<value>` (rlock v0.1.1 added the flag).
  Small projects (single-service compose, tiny codebase, no large
  images) can drop to `4G`–`8G` to save disk on CI cache restores
  and warm-path snapshot extraction.
- Docs: `docs/snapcompose-toml.md` documents the new `[disk]` section.

## v0.1.1 — 2026-05-23

- **docker-engine plugin**: add the `rlock` user to the `docker`
  group during `snapshot_build`. Prebuild commands run as `rlock`
  (per `snapc-prebuild-template.sh`'s `su -l rlock`); without
  group membership any `docker compose` invocation in a prebuild
  step failed with `permission denied while trying to connect to
  the Docker daemon socket`. Snapshot-key suffix bumped v1→v2 to
  invalidate any cached layers from the broken state.

## v0.1.0 — 2026-05-21

Initial public release.

### Distribution plugins
- `mise` (cached cold, tool-version manager).
- `ruby-bundler` / `npm` / `pnpm` / `uv` / `poetry` / `cargo` — dep-installer plugins (incremental cold, `deps = ["mise"]`).
- `docker-engine` (cached cold, host-shared).
- `docker-compose` (cached live, 4G memory, `compose up + healthcheck wait` baked into the snapshot).
- `docker-registry-cache` (cached cold) — host-side pull-through Docker registry mirror (~60 s saved off every cold).

### Project config: `snapcompose.toml`
- `[memory]`, `[prebuild.<name>]`, `[on_start.<name>]` sections (TOML-1.0 strict, duplicate-section rejection).
- Synthesiser (`lib/snapc-prebuild.sh` + `lib/snapc-prebuild-template.sh`) generates one `_prebuild-<name>` plugin per section into `.snapcompose/plugins/`.
- Each prebuild step is its own snapshot layer with its own cache slot.
- `[memory] size` wired to `rl new --memory`.

### Commands
- `snapc run [--no-push] [--vm-suffix=<tag>] -- <cmd>` — one-shot CI runner; auto-creates VM on first call; pushes HEAD via the `rl` git remote; reuses VM across invocations.
- `snapc pr <pr-ref> [--cmd=<cmd>] [--no-isolation]` — runs a GitHub PR / GitLab MR (or local ref under `--no-isolation`) in the project VM. Host-mediated push of the PR head; VM never sees the fork URL.
- `snapc cache` — ls / `--rm <plugin>[:<key>]` / `--rebuild <plugin>` / `--push <oci-ref>` / `--pull <oci-ref>`.

### CI integration
- `.github/workflows/example-snapcompose-ci.yml` — reference workflow with `actions/cache` choreography.
- Companion action `pirj/setup-snapcompose@v1` (separate repo) for one-liner adoption.
- Two-tier cache: `actions/cache` primary, OCI fallback via `snapc cache --push/--pull`. Per-layer dedup means active-PR churn uploads ~50 MB per push (the changed slot), not 2.6 GB.

### Documentation
- `docs/snapcompose-toml.md` — format reference + per-ecosystem snippets (Rails, Django, Phoenix, Go).
- `docs/writing-a-plugin.md` — escape-hatch guide for cases that outgrow `[prebuild.<name>]`.
- `docs/ci-integration.md` — GH Actions workflow guide (one-liner + inline forms + two-tier cache + matrix sharding + `--vm-suffix`).
- `docs/superpowers/specs/` — design specs.

### Tests
- 125/125 bats (plugin TOML / snapshot_key / snapshot_should_skip × every shipped plugin, snapc-run / snapc-pr / snapc-cache flag parsing + flows, `snapc-prebuild` synthesis, OCI push/pull mock, TOML reuse contract).

### Removed
- Per-ecosystem rails-* lifecycle plugins (rails-db-migrations / rails-db-seeds / rails-load-db-schema). Folded into `snapcompose.toml [prebuild.<name>]` sections (one-line shims compound forever across ecosystems; the declarative form generalises).
