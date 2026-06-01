#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    if [ ! -f .go-version ] && [ ! -f mise.toml ] \
       && [ ! -f .tool-versions ] && [ ! -f go.mod ]; then
        echo "skip"
        return
    fi
    {
        cat .go-version      2>/dev/null || true
        cat mise.toml        2>/dev/null || true
        cat .tool-versions   2>/dev/null || true
        cat go.mod           2>/dev/null || true
    } | grep -qiE 'go ' || echo "skip"
}

snapshot_key() {
    {
        cat .go-version      2>/dev/null || true
        cat mise.toml        2>/dev/null || true
        cat .tool-versions   2>/dev/null || true
        # go.mod's `toolchain go1.22.0` directive pins go version. Hash
        # only that line — the rest of go.mod is dependency content which
        # cargo-style fetch is the cargo plugin's concern.
        grep -E '^(go|toolchain) ' go.mod 2>/dev/null || true
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

for f in mise.toml .tool-versions .go-version; do
    [ -f "\$f" ] || continue
    mise trust "\$f" 2>/dev/null || true
done

mise install go
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
