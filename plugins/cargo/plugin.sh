#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

snapshot_should_skip() {
    [ -f Cargo.lock ] || echo "skip"
}

# Snapshot key = SHA256 of Cargo.lock plus Cargo.toml (workspace deps
# can sit in the manifest), plus the rust-toolchain pin if present.
snapshot_key() {
    {
        cat Cargo.lock          2>/dev/null || true
        cat Cargo.toml          2>/dev/null || true
        cat rust-toolchain      2>/dev/null || true
        cat rust-toolchain.toml 2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    if [ ! -f Cargo.lock ]; then
        info "cargo: no Cargo.lock in project root, nothing to fetch"
        return 0
    fi

    # F2 auto-push delivered Cargo.lock + Cargo.toml + rust-toolchain.* to
    # $vm_project_dir before this snapshot_build runs. No scp needed.
    # Triple-escape for nested unquoted heredocs — see ruby-runtime.
    aq exec "$vm" sh <<SH
set -eu
su -l rlock -c "bash -l -s" <<RLOCK
set -eu
eval "\\\$(mise activate bash)"
cd "$vm_project_dir"

command -v cargo >/dev/null 2>&1

cargo fetch --locked
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
