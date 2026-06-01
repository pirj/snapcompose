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
    # Triple-escape for nested unquoted heredocs — see ruby-runtime.
    aq exec "$vm" sh <<SH
set -eu
apk add build-base python3

su -l rlock -c "bash -l -s" <<RLOCK
set -eu
eval "\\\$(mise activate bash)"
cd "$vm_project_dir"

if ! command -v pnpm >/dev/null 2>&1; then
    if command -v corepack >/dev/null 2>&1; then
        corepack enable pnpm
    fi
fi
command -v pnpm >/dev/null 2>&1

pnpm install --prefer-offline
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
