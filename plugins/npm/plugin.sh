#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Skip this layer when there's no package-lock.json — saves ~5-7 s of
# rebase+boot+stop cycle around a no-op snapshot_build.
snapshot_should_skip() {
    [ -f package-lock.json ] || echo "skip"
}

# Snapshot key = SHA256 of package-lock.json plus the Node version
# markers that affect what npm installs.
snapshot_key() {
    {
        cat package-lock.json 2>/dev/null || true
        cat .nvmrc            2>/dev/null || true
        cat .node-version     2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

# Run `npm install` (NOT `npm ci`) so the existing node_modules from the
# previous layer carries over and npm only fetches/links the delta.
# `npm ci` would wipe node_modules first, defeating the incremental
# strategy.
snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    if [ ! -f package-lock.json ]; then
        info "npm: no package-lock.json in project root, nothing to install"
        return 0
    fi

    # Triple-escape for nested unquoted heredocs — see ruby-runtime.
    aq exec "$vm" sh <<SH
set -eu
apk add build-base python3

su -l rlock -c "bash -l -s" <<RLOCK
set -eu
eval "\\\$(mise activate bash)"
cd "$vm_project_dir"

command -v npm >/dev/null 2>&1

npm install --prefer-offline --no-audit --no-fund
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
