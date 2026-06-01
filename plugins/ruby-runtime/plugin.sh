#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Skip when no signal exists that a Ruby version was requested. mise
# can also read `Gemfile`'s `ruby "x.y.z"` directive, so include it.
snapshot_should_skip() {
    if [ ! -f .ruby-version ] && [ ! -f mise.toml ] \
       && [ ! -f .tool-versions ] && [ ! -f Gemfile ]; then
        echo "skip"
        return
    fi
    # If no file mentions ruby at all, skip too. Cheap host-side grep.
    {
        cat .ruby-version    2>/dev/null || true
        cat mise.toml        2>/dev/null || true
        cat .tool-versions   2>/dev/null || true
        cat Gemfile          2>/dev/null || true
    } | grep -qE 'ruby' || echo "skip"
}

# Snapshot key = hash of every file the Ruby version could come from.
snapshot_key() {
    {
        cat .ruby-version    2>/dev/null || true
        cat mise.toml        2>/dev/null || true
        cat .tool-versions   2>/dev/null || true
        # Gemfile's `ruby "x.y.z"` directive: include the whole Gemfile so
        # any ruby pin or ruby-related plugin tweak invalidates the layer.
        cat Gemfile          2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

# Install the project's declared Ruby version via mise. Runs at
# $SNAPC_VM_PROJECT_DIR so mise's auto-config-discovery reads the right
# files (delivered via F2 auto-push).
snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    aq exec "$vm" sh <<SH
set -eu
su -l rlock -c "bash -l -s" <<RLOCK
set -eu
eval "\$(mise activate bash)"
cd "$vm_project_dir"

# Trust whichever config files the project ships before installing.
for f in mise.toml .tool-versions .ruby-version; do
    [ -f "\$f" ] || continue
    mise trust "\$f" 2>/dev/null || true
done

# mise install ruby reads the resolved version from the trusted files
# (.ruby-version takes precedence in the standard mise resolution order).
mise install ruby
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
