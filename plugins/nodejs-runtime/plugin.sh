#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    if [ ! -f .nvmrc ] && [ ! -f .node-version ] && [ ! -f mise.toml ] \
       && [ ! -f .tool-versions ] && [ ! -f package.json ]; then
        echo "skip"
        return
    fi
    {
        cat .nvmrc           2>/dev/null || true
        cat .node-version    2>/dev/null || true
        cat mise.toml        2>/dev/null || true
        cat .tool-versions   2>/dev/null || true
        cat package.json     2>/dev/null || true
    } | grep -qiE 'node|nvm' || echo "skip"
}

snapshot_key() {
    {
        cat .nvmrc           2>/dev/null || true
        cat .node-version    2>/dev/null || true
        cat mise.toml        2>/dev/null || true
        cat .tool-versions   2>/dev/null || true
        # package.json's `engines.node` influences resolution; hash whole file.
        cat package.json     2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    # Triple-escape for nested unquoted heredocs — see ruby-runtime.
    aq exec "$vm" sh <<SH
set -eu
su -l rlock -c "bash -l -s" <<RLOCK
set -eu
eval "\\\$(mise activate bash)"
cd "$vm_project_dir"

for f in mise.toml .tool-versions .nvmrc .node-version; do
    [ -f "\\\$f" ] || continue
    mise trust "\\\$f" 2>/dev/null || true
done

mise install node
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
