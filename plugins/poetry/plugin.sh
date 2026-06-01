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
    aq exec "$vm" sh <<SH
set -eu
su -l rlock -c "bash -l -s" <<RLOCK
set -eu
# mise must be on PATH — this plugin declares deps = ["mise"]. Fail
# loudly rather than silently using a system Python (wrong version).
eval "\$(mise activate bash)"
cd "$vm_project_dir"

# Project must declare poetry (or python + a way to install poetry)
# in mise.toml / .tool-versions. Falling back to apk's py3-poetry would
# bind to the system Python — wrong version, hard-to-debug.
command -v poetry >/dev/null 2>&1

# Keep .venv inside the project so the cache layer captures it.
poetry config virtualenvs.in-project true

# poetry install --no-interaction reads pyproject.toml + poetry.lock
# and installs into .venv. Incremental: pre-existing .venv from earlier
# layer skips already-installed deps.
poetry install --no-interaction --no-ansi
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
