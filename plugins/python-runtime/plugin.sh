#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    if [ ! -f .python-version ] && [ ! -f mise.toml ] \
       && [ ! -f .tool-versions ] && [ ! -f pyproject.toml ]; then
        echo "skip"
        return
    fi
    {
        cat .python-version  2>/dev/null || true
        cat mise.toml        2>/dev/null || true
        cat .tool-versions   2>/dev/null || true
        cat pyproject.toml   2>/dev/null || true
    } | grep -qiE 'python' || echo "skip"
}

snapshot_key() {
    {
        cat .python-version  2>/dev/null || true
        cat mise.toml        2>/dev/null || true
        cat .tool-versions   2>/dev/null || true
        # pyproject.toml's [tool.mise] or [project.requires-python] both
        # influence resolution; hash the whole file.
        cat pyproject.toml   2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    aq exec "$vm" sh <<SH
set -eu
su -l rlock -c "bash -l -s" <<RLOCK
set -eu
eval "\$(mise activate bash)"
cd "$vm_project_dir"

for f in mise.toml .tool-versions .python-version; do
    [ -f "\$f" ] || continue
    mise trust "\$f" 2>/dev/null || true
done

mise install python
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
