#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    [ -f uv.lock ] || echo "skip"
}

# Snapshot key = SHA256 of uv.lock plus pyproject.toml (uv reads both to
# resolve), plus the Python version markers that affect what uv installs.
snapshot_key() {
    {
        cat uv.lock         2>/dev/null || true
        cat pyproject.toml  2>/dev/null || true
        cat .python-version 2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    if [ ! -f uv.lock ]; then
        info "uv: no uv.lock in project root, nothing to install"
        return 0
    fi

    # F2 auto-push delivered uv.lock + pyproject.toml + .python-version
    # to $vm_project_dir before this snapshot_build runs. No scp needed.
    # Triple-escape for nested unquoted heredocs — see ruby-runtime.
    aq exec "$vm" sh <<SH
set -eu
su -l rlock -c "bash -l -s" <<RLOCK
set -eu
eval "\\\$(mise activate bash)"
cd "$vm_project_dir"

command -v uv >/dev/null 2>&1

uv sync --frozen
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
