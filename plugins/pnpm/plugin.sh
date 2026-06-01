#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Skip this layer when there's no pnpm-lock.yaml — saves ~5-7 s of
# rebase+boot+stop cycle around a no-op snapshot_build.
snapshot_should_skip() {
    [ -f pnpm-lock.yaml ] || echo "skip"
}

# Snapshot key = SHA256 of pnpm-lock.yaml plus the Node version markers
# that affect what pnpm installs.
snapshot_key() {
    {
        cat pnpm-lock.yaml 2>/dev/null || true
        cat .nvmrc         2>/dev/null || true
        cat .node-version  2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    if [ ! -f pnpm-lock.yaml ]; then
        info "pnpm: no pnpm-lock.yaml in project root, nothing to install"
        return 0
    fi

    # F2 auto-push delivered pnpm-lock.yaml + package.json + per-project
    # config files to $vm_project_dir before this snapshot_build runs.
    # No scp needed.
    aq exec "$vm" sh <<SH
set -eu
# Native build deps for any modules with node-gyp / sharp / etc.
apk add build-base python3

su -l rlock -c "bash -l -s" <<RLOCK
set -eu
# mise must be on PATH — this plugin declares deps = ["mise"]. Fail
# loudly rather than silently using system Node (wrong version).
eval "\$(mise activate bash)"
cd "$vm_project_dir"

# Project must declare pnpm in mise.toml / .tool-versions / via
# corepack's packageManager field in package.json. If pnpm still isn't
# on PATH after mise activation + corepack auto-provision, fail —
# don't npm install -g pnpm against the wrong Node, don't fall back
# to system pnpm.
if ! command -v pnpm >/dev/null 2>&1; then
    if command -v corepack >/dev/null 2>&1; then
        corepack enable pnpm
    fi
fi
command -v pnpm >/dev/null 2>&1

# pnpm install honours the lockfile and works incrementally — only
# packages absent from the store get fetched, only project node_modules
# entries that differ get re-linked. --prefer-offline keeps already-cached
# tarballs out of the network path entirely.
pnpm install --prefer-offline
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
