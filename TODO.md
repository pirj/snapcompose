# snapcompose TODO

This file tracks distribution-level work — plugins, commands, and design
choices specific to the CI / pre-baked-environment use case. Cross-cutting
items (framework, aq, AI plugins) live in the corresponding repo's TODO.

## North-star: GitHub Actions CI integration

snapcompose is primarily a CI runner. Local PR isolation is a side use case
deferred to a future separate tool (working title `p.rlock`). Anything
below is scored against "does this make GH Actions CI faster / easier".

- [done 2026-05-21, commit 532644c] **Cross-machine snapshot transport
  via `actions/cache`** + the reference workflow
  `docs/example-snapcompose-ci.yml` (moved out of `.github/workflows/`
  on 2026-05-25 — it was a docs example, not snapcompose's own CI).
  The cache dir `~/.local/share/aq/cache/` round-trips between CI
  runs; second-and-later runs hit sub-second-warm.
- [done 2026-05-21, https://github.com/pirj/setup-snapcompose] **Packaged
  action `pirj/setup-snapcompose@v1`** — composite action that does
  install + cache restore + auto-save in one step. Inputs cover ref
  pinning, cache-key segmentation, cache-extra-paths, restore-only
  mode, and AQ_NO_SNAPSHOT_COMPRESS surfacing. Currently private
  during early adoption; v1 tag mutable, will cut v1.0.0 once
  upstream repos stabilise.
- [~] **OCI registry cache transport** (alt / supplement to
  actions/cache). **Shipped**: per-layer `snapc cache --push <oci-ref>`
  / `--pull <oci-ref>` (commit 4ea3750) + two-tier integration in
  setup-snapcompose (`oci-cache-ref` input, GH cache primary + OCI
  fallback). Per-layer model dedups identical slots server-side by
  sha256 — active PR churn uploads ~50 MB per commit (the one
  changed slot), not 2.6 GB. **Remaining**:
  - [ ] `snapc cache --gc <oci-ref>` for periodic cleanup
    (registry-specific manifest enumeration). GHCR has no auto-TTL
    so this matters for long-lived caches.
  - [ ] Chunk-level dedup à la depot.dev (chunk qcow2 files,
    per-chunk content-addressable storage). Deferred until a
    measured pain point appears — for ephemeral CI runners the
    pull-side bandwidth win is marginal; storage-side dedup is the
    real value.

Full design in `docs/superpowers/specs/2026-05-20-snapcompose-toml-and-prebuild.md`
(prebuild) and a future GH-CI-specific spec doc.

## Plugins — shipped baseline

All baseline plugins for the snapcompose CI distribution shipped pre-
2026-05-19:

- [done] **`mise`** — tool-version manager. Cached cold; hashes
  mise.toml / .tool-versions / .ruby-version / .nvmrc.
- [done] **`ruby-bundler`** — incremental cold; deps on mise; runs
  `bundle install` against Gemfile.lock.
- [done] **`npm`** — incremental cold; deps on mise; runs `npm install
  --prefer-offline` against package-lock.json.
- [done 2026-05-19, commit 314476f] **`uv`** / **`poetry`** / **`pnpm`** /
  **`cargo`** — dep-installer plugins mirroring the npm / ruby-bundler
  shape (incremental cold, deps on mise). Each scp's its lockfile +
  manifest into /home/rlock/repo, then runs the install command via
  mise-managed tooling. `cargo` stops at `cargo fetch` (target/ build
  is the user's call).
- [done 2026-05-19, commit 29a75fd] **`docker-engine`** + **`docker-
  compose`** (cached cold + cached live) + **`docker-registry-cache`**
  for the host-side pull-through Docker registry.

## Plugins — supplanted by snapcompose.toml
- [supplanted by snapcompose.toml] **rails-* lifecycle plugins**
  (`rails-db-migrations`, `rails-db-seeds`, `rails-load-db-schema`) —
  originally planned as separate ecosystem plugins. The 2026-05-20
  design review concluded these are one-line shims around a single
  `docker compose exec app rails db:<verb>` command each; making them
  separate plugins would compound to N similar shims per ecosystem
  (Django manage.py, Phoenix mix ecto, ...). Folded into
  `snapcompose.toml` `[prebuild.<name>]` sections instead. The Rails
  reference snippet ships in [snapcompose-toml.md doc — TODO]; rails-*
  semantics map directly to:

    ```toml
    [prebuild.schema-load]
    cmd = "docker compose exec app rails db:schema:load"
    key_files = ["db/schema.rb"]            # strategy defaults to cached

    [prebuild.migrate]
    cmd = "docker compose exec app rails db:migrate"
    key_files = ["db/schema.rb", "db/migrate"]  # NOT incremental — see spec note

    [prebuild.seed]
    cmd = "docker compose exec app rails db:seed"
    key_files = ["db/seeds.rb"]
    ```

  See `docs/superpowers/specs/2026-05-20-snapcompose-toml-and-prebuild.md`
  for the full reasoning (in particular: why `rails db:migrate` is NOT
  `incremental` — silent correctness bug on edited migrations).

## snapcompose.toml — project config + prebuild synthesis

Full design in `docs/superpowers/specs/2026-05-20-snapcompose-toml-and-prebuild.md`.

- [done 2026-05-20, commit 1c11e46] `lib/snapc-prebuild.sh` synthesiser
  + `lib/snapc-prebuild-template.sh` runtime template. Each
  `[prebuild.<name>]` becomes its own snapshot layer with its own
  cache slot. 18 bats.
- [done 2026-05-20, commit dc25e11] `snapc-run` reads snapcompose.toml,
  synthesises `.snapcompose/plugins/_prebuild-*`, exports
  `RLOCK_PLUGIN_PATH`, appends synthesised plugins to `rl new`.
- [done 2026-05-21, rlock commit pending] **prereq:** rlock's
  `RLOCK_PLUGIN_PATH` — colon-separated PATH-like list of plugin
  directories. Replaces the older `PLUGIN_USER_DIR` / `PLUGIN_USER_DIRS`
  pair entirely; the singular `PLUGIN_USER_DIR` form is gone. Default
  when unset: `~/.config/rl/plugins`. Earlier entries win on name
  conflicts.
- [done 2026-05-20, rlock commit 2d46847] **prereq:**
  `toml_get_array_in_section` in rlock's `lib/toml.sh` — section-
  aware array reader needed by the synthesiser.
- [done 2026-05-21, commit ab40f7a] **`docs/snapcompose-toml.md`** —
  format reference + per-ecosystem snippets (Rails, Django, Phoenix,
  Go modules). Cached/incremental contract with the rails-migrate
  caveat front-and-centre.
- [done 2026-05-21, commit 5546d20] **`docs/writing-a-plugin.md`** —
  escape-hatch guide for cases that outgrow `[prebuild.<name>]`.
- [done 2026-05-21, commit 981acbf + rlock 58d8fef] **`[memory] size`
  in snapcompose.toml** — overrides `aq new --memory` via the new
  `rl new --memory=NG` flag. Takes precedence over the per-plugin
  max_snapshot_memory derivation; falls back to it when omitted.
- [ ] **`plugin = "<name>"` reference in `[prebuild.<name>]`** for
  interleaving prebuild steps between existing plugins. Pivots
  snapcompose.toml to be the authoritative chain spec. Deferred until
  prebuild-MVP demonstrates the need.

## Commands to add

- [done 2026-05-19, commit 6 weeks ago] **`snapc run`** — one-shot
  CI job runner. Reads snapcompose.toml, auto-provisions VM if missing
  (triggered plugins + synthesised prebuild), pushes HEAD via the
  `rl` git remote, exec's the command, propagates exit code.
- [done 2026-05-21, commit pending] **`snapc run --vm-suffix=<tag>`**
  for parallel-in-one-job VMs. Prereq: rlock's `rl new --name=<vm>`
  flag (commit pending in rlock) — lets snapc-run pin the synthesised
  VM name to `<basename>-<suffix>` rather than the cwd-derived
  default. Each suffixed VM has its own state + cache slot; layer
  cache (under $RL_CACHE_DIR) is shared by `(plugin, snapshot_key)`
  so the snapshot layers transparently reuse across suffixes.
- [~] **`snapc pr`** — partial: GitHub PR URLs + GitLab MR URLs +
  `--no-isolation` shipped 2026-05-19 (commit e03ff1a). **Remaining**:
  - [ ] Bitbucket PR URLs (no widely-deployed CLI; needs HTTP-API
    path).
  - [ ] Auto-detect command from `.github/workflows/*.yml` /
    `.gitlab-ci.yml` so `snapc pr <url>` works without `--cmd`.
- [ ] **`snapc snapshot ls / rm / inspect`** — explicit management of
  the layered cache. Wrap `aq snapshot` underneath. (Current
  `snapc-cache` covers ls/rm; `inspect` for layer parent chains +
  per-key metadata is the gap.)
- [ ] **Cleanup of stale `_snapc_run` / `_snapc_pr` refs on the VM**.
  Each `snapc run` / `snapc pr` force-pushes to a dedicated ref
  (`refs/heads/_snapc_run`, `refs/heads/_snapc_pr`). They accumulate
  on the guest's git tree across many invocations. Add an `rl rm`
  hook (or a periodic GC step) to drop refs older than N days.

## docker-compose kind = "live"

- [done 2026-05-19] `docker-compose/plugin.toml` is now
  `kind = "live"` with `memory = "4G"`. aq's `--memory=NG` flag (aq
  v2.5.0) and the framework's per-plugin `memory` declaration both
  shipped together; the docker-compose flip followed. Live restore
  on the rails-pg-sample fixture measured at ~1.3 s end-to-end (see
  `../benchmark-2026-05-19-c-live-restore.md`).

## Distribution-specific UX

- `snapc run` and `snapc pr` need a way to surface measurement (cold/warm
  wall-clock per job). Tie into the framework's planned snapshot
  analytics (`rl cache stats` — see `rlock/TODO.md`).
- "Per-VM CPU/memory caps for shards" — already an `aq` follow-up under
  fanout. Surface from `snapc run --max-cpu --max-mem` once aq supports.
- [ ] **`examples/` directory** — ready-to-fork project skeletons
  showing canonical `snapcompose.toml` + `.github/workflows/ci.yml`
  pairs per ecosystem (Rails+PG, Django+PG, Phoenix+PG, plain
  Node/pnpm, Go modules, ...). The per-ecosystem snippets in
  `docs/snapcompose-toml.md` are reference fragments; an
  `examples/<ecosystem>/` carries a working fixture you can clone
  and adapt. Build incrementally — first Rails+PG (reuse
  `test/fixtures/rails-pg-sample`), then add ecosystems as adopter
  demand surfaces.

## Shared docker-engine layer

`docker-engine`'s `snapshot_key` is a content hash that doesn't depend
on the project — every snapcompose project that activates Docker chains
off the same cached snapshot. Measurement TODO: how much disk does
this single snapshot occupy and how much time does it save versus a
cold install? (~30 s install, ~470 MiB snapshot — confirm.)

## Potential performance improvements (2026-05-29 research)

Catalogued from a 4-track research dive. Source: [`../meta/2026-05-29-optimization-research-top10.md`](../meta/2026-05-29-optimization-research-top10.md). Not actively in flight — recorded so we don't re-derive next time we revisit cold/warm latency. Items here are the ones whose natural home is snapcompose (per-plugin cmd, prebuild side, distribution UX); cross-cutting QEMU/aq items live in [`../aq/ROADMAP.md`](../aq/ROADMAP.md) under "Potential performance improvements"; CI/cache items in [`../setup-snapcompose/TODO.md`](../setup-snapcompose/TODO.md); rlock framework items in [`../rlock/TODO.md`](../rlock/TODO.md).

- [ ] **`vmtouch` hot pages into `memory.bin` at snapshot save time** — `apk add vmtouch && vmtouch -t /var/lib/docker/overlay2 /usr/bin/dockerd /usr/lib/postgres*` as a final step of each cold prebuild plugin (or as a snapcompose-wide pre-snapshot hook). Pre-populates the page cache so it's RAM-resident at `qmp migrate` time → included in `memory.bin` → no page fault on first `docker-compose up` after warm restore. Expected: M3 0 ms warm restore itself (the saving is on the FIRST guest request after the VM is up); cuts ~500-1500 ms off first `docker-compose up` post-warm. 1 LoC per plugin or one shared step. Zero risk. [vmtouch](https://github.com/hoytech/vmtouch).
- [ ] **`eatmydata` LD_PRELOAD for cold prebuild plugins** — turns `fsync`/`fdatasync` into no-ops during `apk add`, `docker pull`, schema migration etc. Cold path is fsync-dominated on Azure block storage (10-50 ms per fsync × hundreds of fsyncs). Expected: M3 cold -5 to -15 s of the 95 s base build; CI cold -20 to -60 s of the 232 s. ~3 LoC: `apk add eatmydata` in `_base`/`docker-engine`, then prefix `apk` / `docker` calls with `eatmydata` in each prebuild plugin. **Caveat**: must `sync` before `aq snapshot create`, otherwise the captured disk state is half-flushed. Add `sync && sleep 0.2` in `snapc-prebuild.sh`'s pre-snapshot hook.
- [ ] **s6-overlay (or runit) for prebuild VMs only** — Alpine's OpenRC sequential boot is ~1.5-2.5 s from `/sbin/init` to `sshd` accept. s6-overlay (used by many container bases) gets down to ~400-700 ms. Only affects the COLD base build path (warm restore skips init entirely), so the saving is M3 cold -800 to -1500 ms / CI cold -1.5 to -3 s. ~200-400 LoC of Alpine `setup-alpine` customisation. Distro-level change; defer until everything cheaper is shipped.
- [ ] **`docker-registry-cache` measurement on CI** — already shipped 2026-05-19 (commit 29a75fd) as a snapcompose plugin (CNCF distribution binary in proxy mode on `127.0.0.1:5000`). M3 saves ~60 s on every cold `rl new` after the first on the host. CI numbers unmeasured — the cache restore on a fresh runner may or may not preserve the registry's blob store. Worth a 1-day sprint to bench-confirm and document.

### Explicitly NOT pursuing

- **Devcontainers / VS Code Dev Containers as a snapcompose UX target.** Different threat model (container reuse without VM isolation), different speed profile (much faster, much less isolated). Worth tracking but not converging onto.

## Consolidate `snapc-run` / `snapc-pr` / `snapc-cache` into one `snapc-cli` plugin

Surfaced by the 2026-05-19 architecture review (Issue 1) — see
[`architecture-review-2026-05-19.md`](../architecture-review-2026-05-19.md).

Today, each of the three command-only plugins declares the same 10-entry
trigger list (Dockerfile, docker-compose.\*, mise.toml, .tool-versions,
.ruby-version, .nvmrc, .node-version, Gemfile.lock, package-lock.json) —
the union of distribution-relevant files. Adding a new dep installer
(uv, pnpm, poetry, ...) requires updating its triggers AND all three
bake-\* plugins. Triplication invites drift.

Fix: collapse into a single `snapc-cli` plugin:

```
plugins/snapc-cli/
  plugin.toml              # commands = ["snapc-run", "snapc-pr", "snapc-cache"]
                           # trigger list (single source of truth)
  commands/
    snapc-run.sh            # moved from plugins/snapc-run/commands/
    snapc-pr.sh             # moved from plugins/snapc-pr/commands/
    snapc-cache.sh          # moved from plugins/snapc-cache/commands/
```

Framework already supports multiple `commands = [...]` per plugin (used
by `auth-proxy` declaring `auth`, `branch` declaring `branch`, etc.).
The command scripts don't change; just the directory layout + the three
old `plugin.toml` files merge into one.

Tests: rename test files (`bake_run.bats` -> `bake_cli_run.bats` or
keep names), update `PLUGIN_DIR` to point at `plugins/snapc-cli`. Net
test count unchanged.

[done 2026-05-19, commit 29a75fd] Pre-warmed docker image cache on host. Shipped as `docker-registry-cache` plugin: CNCF distribution binary in proxy mode on 127.0.0.1:5000; guest dockerd configured via daemon.json `registry-mirrors` to 10.0.2.2:5000. ~60 s saved off every cold rl new after the first on the host. host_deps = ["registry"] (brew install docker-distribution-distribution on macOS).

## Open design questions

- **PR-from-untrusted-fork model.** Two options:
  - Host adds the untrusted git repo as an `rl` remote and code reaches
    the VM via git push only — same model as ai.rlock for safety.
  - VM clones the fork directly (network-permitted in CI). Faster, less
    safe against malicious refs / fetch hooks.
  Recommendation: start with model A for `snapc pr`, document the
  tradeoff. Model B can be opt-in for "trusted CI" use cases.
- **What's the smoke fixture project?** A minimal Rails+Postgres app
  lives in `test/fixtures/rails-app/` in the rlock repo today. Whether
  to keep it there (so framework integration tests use it) or move it
  here is TBD.

## CI compose override — adoption-blocking

Filed 2026-05-30 from the OSS Rails CI survey
([`../meta/research-2026-05-30-rails-oss-ci-survey.md`](../meta/research-2026-05-30-rails-oss-ci-survey.md)).

**Problem.** Among 100 actively-maintained Rails projects in
[real-world-rails](https://github.com/eliotsykes/real-world-rails),
~22 ship a `docker-compose.yml` whose `app` service has `build:`
(production / Kamal shape) — and **all 22** keep CI on
`ruby/setup-ruby + services: postgres redis`. The dev compose file
is a laptop-`docker compose up` shortcut; the CI file (where it
exists) is a separate `docker-compose.test.yml` / `.ci.yml` with
infrastructure only. snapcompose's `docker-compose` plugin
currently autodiscovers `docker-compose.yml` at the project root
and runs `docker compose build && up -d` on whatever it finds —
which for these projects means rebuilding the prod app image on
every cold CI, which is exactly what they chose `ruby/setup-ruby
+ services:` to avoid.

Without an override, snapcompose can't be adopted by these
projects without asking them to restructure their existing dev
compose file — which they will refuse.

**What the feature looks like.**

- [ ] **Path override** in `snapcompose.toml`:

  ```toml
  [docker-compose]
  file = "docker-compose.ci.yml"
  ```

  Plugin reads `file` (if present) instead of falling back to the
  `docker-compose.yml` autodiscover. Compatible with v0.2.x users
  who don't set the key.

- [ ] **Service-list filter** in `snapcompose.toml` (alternative,
  same section):

  ```toml
  [docker-compose]
  services = ["db", "redis"]
  ```

  Plugin runs `docker compose up -d db redis` instead of
  `docker compose up -d` over everything. Useful when the project
  doesn't want a second compose file and the dev compose has clean
  service names.

- [ ] **Both keys are optional, order of precedence: `services`
  filter wins over `file`** (the override is what the project
  *wants* in CI; the file is the *source*). Document the
  interaction in [`docs/snapcompose-toml.md`](docs/snapcompose-toml.md).

- [ ] **Bats integration test** in `test/`: fixture project with
  `docker-compose.yml` (full stack) + `docker-compose.ci.yml`
  (db only); assert snapcompose-with-override only brings up the
  db, ignores the rest.

**GTM impact (per `../meta/gtm-playbook.md`).** This feature is
the prerequisite for the "snapcompose adoption — OSS Rails
outreach" sub-section. Without it, the outreach surface is ~5
projects (those that already do compose-in-CI); with it, the
surface is ~22 active projects with measured CI duration savings.

Ships as an additive `[docker-compose]` section in
`snapcompose.toml`; default behaviour unchanged. Snapcompose minor
bump alongside whatever else is in flight.

## Canonical `[services.<name>]` declaration in `snapcompose.toml`

Filed 2026-05-30 from the OSS Rails CI services-survey follow-up.

**Motivation.** GHA `services:` is the dominant API surface for
declaring container side-cars in CI workflows. Mirroring that
shape in `snapcompose.toml` removes the conceptual mismatch
between "what I declare in CI today" and "what I declare for
snapcompose." Users copy-paste their `services:` block (minor
syntax tweaks: `env` → `environment`, `options:` → translates to
`healthcheck`) and snapcompose snapshots the running stack.

**Schema:**

```toml
[services.db]
image = "postgres:16-alpine"
environment = { POSTGRES_PASSWORD = "dev" }
ports = ["5432:5432"]
options = "--health-cmd pg_isready --health-interval 2s"

[services.redis]
image = "redis:7-alpine"
```

**Implementation.** docker-compose plugin gets a second entry path:

- [ ] If `snapcompose.toml` has any `[services.*]` sections, plugin
      generates a transient `docker-compose.yml` from them
      (`.snapcompose/services.docker-compose.yml`), runs
      `docker compose -f <that> up -d`, waits healthchecks.
      Otherwise falls back to autodiscover behaviour.
- [ ] `[services.*]` and `[docker-compose] file = ...` are mutually
      exclusive; specifying both is a hard error at snapcompose.toml
      parse time.
- [ ] Document the schema in `docs/snapcompose-toml.md` with a
      side-by-side translation table (GHA `services:` ↔ snapcompose
      `[services.*]` ↔ docker-compose `services:`).
- [ ] Bats test: fixture with both styles, assert identical warm
      state.

**Snapshot semantics unchanged.** `snapshot_key` is the sha256 of
the rendered transient compose file (which is deterministic from
the `[services.*]` blocks). Cache hits + chain semantics work
identically.

## Phase 2 — GitLab CI adapter

Filed 2026-05-30 (deferred). GitLab CI is the closest cousin to
GHA: same `services:` keyword in `.gitlab-ci.yml` job blocks, same
docker-runtime model, syntax nearly 1:1. Survey of OSS Rails put
GitLab CI at ~5% of active projects (vs. ~85% on GitHub Actions),
so this is **Phase 2 after PMF on GHA**, not parallel.

What ships when this is picked up:

- [ ] `setup-snapcompose-gitlab` — analogue of the existing GHA
      composite action. Bash include in `.gitlab-ci.yml` that does
      install (aq + rlock + snapcompose) + cache restore + cache
      save via GitLab's built-in `cache:` keyword.
- [ ] Documentation page mirroring `docs/example-snapcompose-ci.yml`
      but for `.gitlab-ci.yml`.
- [ ] One worked example in a popular GitLab-hosted Rails project
      (likely on gitlab.com — find one as part of the OSS Rails
      outreach campaign).

**Out of scope:** CircleCI, Jenkins, Buildkite, Drone, Concourse,
Azure Pipelines. CircleCI's docker-executor model is conceptually
different (each job gets its own container with secondary
service containers). Jenkins varies too much per setup. None
warrant native support until measured demand.

**snapcompose core stays platform-agnostic.** The qcow2 chain
orchestration + plugin protocol + snapcompose.toml schema don't
change between CI platforms. Only the install + cache-transport
wrapper differs.

## Architectural refactor wave — explicit activation + mise split

Filed 2026-06-01 from the walking-skeleton debugging conversation.
These four items are interconnected; ship them in one wave so the
plugin protocol bumps once.

### 1. `plugins = [...]` in `snapcompose.toml` (explicit activation)

**Today.** A plugin enters the resolved chain through one of:
- Trigger-file presence (`.ruby-version` → mise)
- Transitive dep pull (`ruby-bundler.deps = ["mise"]`)
- Explicit CLI arg (`rl new <plugin>`)
- A synthesised `[prebuild.<name>]` section

The trigger mechanism conflates "should this plugin even be in
the chain?" with "does its work matter?". A project with
`.python-version` instead of `.ruby-version` doesn't activate the
mise plugin even though mise itself handles `.python-version`
just fine. Same for projects that pin Ruby in `Gemfile` rather
than `.ruby-version`. The list-of-triggers is hardcoded; mise
upstream supports ~24 idiomatic config files; ours covers 4.

**Proposed.** Add an explicit list to `snapcompose.toml`:

```toml
plugins = [
  "docker-engine",
  "docker-compose",
  "mise",
  "ruby-bundler",
  # "npm",
  # "uv",
]
```

Semantics:
- If the section is present, that's the **canonical activation
  source**. The framework still resolves transitive deps (one
  entry's `deps = [...]` pulls more plugins in), but does NOT
  auto-detect by trigger.
- If the section is absent, behave as today (back-compat).
- Each entry is a concrete plugin name (`ruby-bundler`, `npm`,
  `uv`, `poetry`), NOT a language shortcut. A package.json could
  belong to npm OR pnpm; the user picks. Language shortcuts are
  layered on top (see item 4).
- If a plugin in the list has nothing to do (empty content for
  its `snapshot_key` — e.g. mise is listed but no tool-version
  files exist anywhere), emit a `warn` at chain-walking time:
  "plugin 'mise' activated but no runtime versions declared;
  layer will be a no-op snapshot slot."

**Snapcompose-auto-CI compatibility.** A future
`snapcompose-auto-CI` plugin (Phil's parallel session) can read
the GitHub Actions workflow's `services:` block + detect
`setup-ruby` etc., and generate this `plugins = [...]` list +
`[services.*]` blocks on the fly. The explicit-list model makes
that auto plugin trivially composable — it only needs to write
TOML.

**Implementation:**
- [ ] Parse `plugins` array from `snapcompose.toml` in `snapc-run`.
- [ ] When present, skip `detect_triggers` (or run it advisory-
      only).
- [ ] When empty-key plugin emits, warn but don't fail (it's a
      valid no-op slot).
- [ ] Doc table in `docs/snapcompose-toml.md` showing the four
      activation paths and their precedence.
- [ ] Bats: project with explicit `plugins = ["mise"]` but no
      `.ruby-version` activates mise → warn → builds an empty
      snapshot layer → cached normally.

### 2a. `snapc run` honours `SNAPC_VM_PROJECT_DIR` for user commands

**Today.** `snapc-run`'s SSH command is hardcoded:

```bash
do_ssh "$vm_name" "cd repo 2>/dev/null && ...; bash -lc 'cd ~/repo && $*'"
```

— it always lands the user's command at `/home/rlock/repo`, the
monorepo root. For subdirectory snapcompose projects (F1 already
exports `SNAPC_VM_PROJECT_DIR=/home/rlock/repo/services/<svc>` for
plugins), the user command runs in the wrong dir — `docker compose
ps` errors with "no configuration file provided" because the
compose file is in the subdir. Workaround in benchmark workflow:
`snapc run -- 'cd services/main && docker compose …'` — but every
adopter would hit this.

**Fix.** snapc-run honours `SNAPC_VM_PROJECT_DIR` for the user
command too:

```bash
do_ssh "$vm_name" "bash -lc 'cd ${SNAPC_VM_PROJECT_DIR:-~/repo} && $*'"
```

- [ ] Patch snapc-run.sh.
- [ ] Bats: subdir fixture (`services/main/snapcompose.toml` +
      compose), `snapc run -- 'pwd; ls'` from
      `<repo>/services/main` returns `/home/rlock/repo/services/main`
      and lists docker-compose.yml.

### 2. Drop redundant scp from mise / ruby-bundler / npm / uv / poetry / pnpm / cargo

Same cleanup as F3 (docker-compose). All these plugins predate
F2's auto-push and scp their config files into the VM
separately. With F2, source arrives at
`/home/rlock/repo/<subdir>` via git push before any plugin's
`snapshot_build` runs. The scp loops are dead code.

- [ ] mise: drop the `aq scp` of `mise.toml` / `.tool-versions`
      / `.ruby-version` / `.nvmrc`. `cd "$SNAPC_VM_PROJECT_DIR"`
      and run `mise install` — it'll read whatever's in the
      pushed source tree.
- [ ] ruby-bundler: drop `aq scp` of `Gemfile` / `Gemfile.lock`.
      `cd "$SNAPC_VM_PROJECT_DIR"` and `bundle install`.
- [ ] Same for npm, uv, poetry, pnpm, cargo.

Each is a 5-10 line change per plugin. Bats integration tests
need re-validation.

### 3. Split mise into mise-base + per-language runtimes

**Today.** mise plugin = single snapshot layer = installs the
mise binary AND every declared runtime (Ruby + Python + Node +
...) in one go. Snapshot_key hashes all tool-version files
together. **Any version bump invalidates the entire layer**,
even if only one language's version moved.

**Proposed.** Split:

```
mise-base              installs the mise binary (key: mise version)
   ↓
ruby-runtime           mise install ruby (key: .ruby-version + Gemfile ruby pin)
python-runtime         mise install python (key: .python-version + pyproject.toml pin)
nodejs-runtime         mise install node (key: .nvmrc / .node-version / package.json engines)
go-runtime             mise install go (key: go.mod toolchain directive)
rust-runtime           mise install rust (key: rust-toolchain.toml)
   ↓
ruby-bundler           deps = ["ruby-runtime"]
npm                    deps = ["nodejs-runtime"]
uv / poetry            deps = ["python-runtime"]
cargo                  deps = ["rust-runtime"]
```

Then a polyglot project (Rails + Python sidecar + Node frontend)
that bumps only the Ruby version invalidates `ruby-runtime` +
`ruby-bundler` — Python and Node layers stay warm. Today this
would invalidate the entire mise layer + every downstream.

**Implementation:**
- [ ] New plugins: `mise-base`, `ruby-runtime`, `python-runtime`,
      `nodejs-runtime`, `go-runtime`, `rust-runtime`.
- [ ] mise-base's snapshot_build installs only the mise binary.
- [ ] Each `<lang>-runtime` plugin's snapshot_build runs
      `mise install <lang>` after `cd "$SNAPC_VM_PROJECT_DIR"`.
- [ ] snapshot_key per runtime hashes only the files relevant to
      that language (see "Proposed" section above).
- [ ] Update dep declarations:
      - `ruby-bundler.deps = ["ruby-runtime"]` (was `["mise"]`)
      - `npm.deps = ["nodejs-runtime"]`
      - `uv.deps = ["python-runtime"]`
      - `poetry.deps = ["python-runtime"]`
      - `cargo.deps = ["rust-runtime"]`
- [ ] Deprecate the monolithic `mise` plugin. Keep as a v0.2.x
      alias that synthesises the new chain (back-compat for old
      `snapcompose.toml` files).
- [ ] Bats integration: polyglot fixture (Ruby + Python +
      Node), assert independent invalidation when only one
      `.X-version` changes.

### 4. Language shortcuts (UX layer)

Optional sugar on top of item 1's `plugins = [...]`:

```toml
plugins = [
  "ruby",       # expands to [mise-base, ruby-runtime, ruby-bundler]
  "nodejs",     # expands to [mise-base, nodejs-runtime, npm]  
  "python",     # expands to [mise-base, python-runtime, uv]  
                # (or poetry if poetry.lock present; or warn if ambiguous)
]
```

Implementation:
- [ ] Maintain a static expansion table in
      `lib/plugin-shortcuts.sh` (or `snapcompose-toml.md` as
      ref): `<shortcut> → [<expanded plugins>]`.
- [ ] During chain resolution, expand shortcuts before passing
      the list to `resolve_deps`.
- [ ] When a shortcut is ambiguous (Python could be uv or
      poetry; Node could be npm or pnpm), pick by lockfile
      presence; if both lockfiles exist, error with "ambiguous
      shortcut 'python'; specify 'uv' or 'poetry' explicitly."
- [ ] Document the shortcut table in
      `docs/snapcompose-toml.md`.

**Naming guideline.** Shortcuts are introduced only where
unambiguous (`ruby` → ruby-bundler tooling is essentially the
only choice). For tooling-choice cases (Python's uv vs.
poetry; Node's npm vs. pnpm vs. yarn), the user names the
specific plugin. **Concrete plugin names always win** —
shortcuts are convenience, not abstraction.

### Why all four together

The plugin protocol bumps once for this wave (the
`mise` → `mise-base + *-runtime` split is the schema-changing
bit; everything else is additive). Cleaner CHANGELOG, single
bats-regression pass, single setup-snapcompose pin bump. Splitting
across releases risks intermediate states where item 2 lands
without item 1 and the activation behaviour gets confusing.

**Anticipated outcome for the walking-skeleton.** With explicit
`plugins = [...]` activation:

- mise can no longer silently skip — it's in the list, so the
  walker MUST process its iteration (or warn loudly if there's
  nothing to do).
- The "mise plugin's iteration mysteriously missing on cold
  chain" bug (Task #22 in the conversation log) is probably
  resolved or surfaces with a clear warning instead of a hidden
  skip.

We continue the walking-skeleton restructure to pg+redis-only
in parallel; the bug becomes a deferred / merged item once this
refactor lands.
