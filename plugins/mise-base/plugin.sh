#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Snapshot key = constant per mise package version (we ride Alpine's
# packaging of mise). Bump the suffix when the apk-install set changes
# so cached chain layers from older mise-base contents get rebuilt.
# v3 adds bzip2-dev, sqlite-dev, xz-dev — Python 3.12.x's source build
# detects these at ./configure time and skips _bz2, _sqlite3, _lzma
# stdlib C extensions when absent. Downstream consumers (e.g. ruby-
# build's Python helpers, project code importing those modules) then
# trip ModuleNotFoundError. Without them, snapcompose-benchmark
# plus5 par cold trips at mise's Ruby compile because ruby-build's
# Python helpers call into bz2 module.
# v2 added python3 — required by Node's ./configure during mise's
# from-source nodejs install (Alpine ships glibc-only binaries from
# nodejs.org, so mise falls back to source build on musl).
snapshot_key() {
    printf 'mise-base-v4' | sha256sum | cut -d' ' -f1
}

# Install mise + the build deps that mise needs when it compiles language
# runtimes from source on Alpine. This is the only layer in the chain
# that installs apk packages for the toolchain; per-language runtimes
# build on top of this.
snapshot_build() {
    local vm="$1"
    aq exec "$vm" sh <<'SH'
set -eu
# mise is in Alpine community since 3.20. Bundling build deps here keeps
# the per-language runtime layers focused on `mise install <lang>`.
# python3: required by Node's ./configure (v8 build) when mise compiles
# nodejs from source. nodejs.org's official binaries are glibc-only;
# Alpine is musl, so mise must source-build node.
# bzip2-dev / sqlite-dev / xz-dev: needed by Python 3.x's source build
# so the _bz2 / _sqlite3 / _lzma stdlib C extensions get built. Without
# them, Python compiles cleanly but `import bz2` etc. trips
# ModuleNotFoundError. ruby-build's Python helpers hit this path on
# +5 par cold (mise compiles Python concurrently with Ruby).
apk add mise build-base openssl-dev readline-dev yaml-dev zlib-dev libffi-dev python3 \
        bzip2-dev sqlite-dev xz-dev

# Activate per-user so subsequent layers' bash -lc shells see mise on
# PATH and have mise shims wired up. Also pin
# `idiomatic_version_file_enable_tools` explicitly so the layer chain
# doesn't break when mise crosses 2025.10.0 — that release flips the
# default for the per-language `.ruby-version` / `.python-version` /
# `.nvmrc` / `.node-version` / `.go-version` discovery from enabled
# to DISABLED. Without the pin, ruby-runtime / python-runtime /
# nodejs-runtime / go-runtime plugins would all fail to detect the
# project's pinned version after that mise version lands on the host.
# Alpine 3.22 currently ships mise 2025.5.10-r0; the warning surfaces
# on every `mise install` invocation, telling us this exact pin will
# matter when Alpine updates to a later mise.
su -l rlock -c 'bash -l -s' <<'RLOCK'
set -eu
grep -q "mise activate" ~/.profile 2>/dev/null \
    || echo 'eval "$(mise activate bash)"' >> ~/.profile
mkdir -p ~/.config/mise
cat > ~/.config/mise/config.toml <<'TOML'
[settings]
# Pin the pre-2025.10.0 default explicitly so the per-language
# runtime plugins keep reading .ruby-version / .python-version /
# .nvmrc / .node-version / .go-version after mise's default flips.
idiomatic_version_file_enable_tools = ["ruby", "python", "node", "go", "rust"]
TOML
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
