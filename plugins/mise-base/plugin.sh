#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Snapshot key = constant per mise package version (we ride Alpine's
# packaging of mise). Bump the suffix when the apk-install set changes
# so cached chain layers from older mise-base contents get rebuilt.
# v2 adds python3 — required by Node's ./configure during mise's
# from-source nodejs install (Alpine ships glibc-only binaries from
# nodejs.org, so mise falls back to source build on musl).
snapshot_key() {
    printf 'mise-base-v2' | sha256sum | cut -d' ' -f1
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
apk add mise build-base openssl-dev readline-dev yaml-dev zlib-dev libffi-dev python3

# Activate per-user so subsequent layers' bash -lc shells see mise on
# PATH and have mise shims wired up.
su -l rlock -c 'bash -l -s' <<'RLOCK'
set -eu
grep -q "mise activate" ~/.profile 2>/dev/null \
    || echo 'eval "$(mise activate bash)"' >> ~/.profile
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
