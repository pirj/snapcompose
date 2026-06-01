#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    [ -f poetry.lock ] || echo "skip"
}

# Snapshot key = SHA256 of poetry.lock plus pyproject.toml (poetry reads
# both to install), plus Python version markers.
snapshot_key() {
    {
        cat poetry.lock     2>/dev/null || true
        cat pyproject.toml  2>/dev/null || true
        cat .python-version 2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    if [ ! -f poetry.lock ]; then
        info "poetry: no poetry.lock in project root, nothing to install"
        return 0
    fi

    # F2 auto-push delivered poetry.lock + pyproject.toml + .python-version
    # to $vm_project_dir before this snapshot_build runs. No scp needed.
    # Triple-escape for nested unquoted heredocs — see ruby-runtime.
    aq exec "$vm" sh <<SH
set -eu
su -l rlock -c "bash -l -s" <<RLOCK
set -eu
eval "\\\$(mise activate bash)"
cd "$vm_project_dir"

command -v poetry >/dev/null 2>&1

poetry config virtualenvs.in-project true

poetry install --no-interaction --no-ansi
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
