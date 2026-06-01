#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Tell the framework to skip this iteration when no tool-version files
# exist in the project root. Saves the ~5-7 s rebase+boot+stop cycle the
# framework would otherwise spend wrapping a no-op snapshot_build.
snapshot_should_skip() {
    if [ ! -f mise.toml ] && [ ! -f .tool-versions ] \
       && [ ! -f .ruby-version ] && [ ! -f .nvmrc ]; then
        echo "skip"
    fi
}

# Snapshot key = hash of all tool-version-declaring files in the project root.
# Any of these missing = no contribution to the hash. The `|| true` keeps a
# missing file from tripping the surrounding `set -e`.
snapshot_key() {
    {
        cat mise.toml      2>/dev/null || true
        cat .tool-versions 2>/dev/null || true
        cat .ruby-version  2>/dev/null || true
        cat .nvmrc         2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

# Install mise inside the VM, trust the project's tool-version files, and
# resolve every declared tool. The tool-version files arrive at
# $SNAPC_VM_PROJECT_DIR via the framework's auto-push (F2); no separate scp
# loop needed.
#
# mise builds runtimes from source on Alpine for most languages, so this
# step can be slow on first run — that's the whole point of caching it.
snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    aq exec "$vm" sh <<SH
set -eu
# \`mise\` is in Alpine community since 3.20. Bundled with build deps that
# many language runtimes need when mise compiles from source.
apk add mise build-base openssl-dev readline-dev yaml-dev zlib-dev libffi-dev

# Activate per-user, trust the project files at the canonical project dir
# (auto-push delivered them), install everything.
su -l rlock -c "bash -l -s" <<RLOCK
set -eu
grep -q "mise activate" ~/.profile 2>/dev/null \\
    || echo 'eval "\$(mise activate bash)"' >> ~/.profile

eval "\$(mise activate bash)"

cd "$vm_project_dir"

# Trust whichever tool-version files the project ships. mise looks for
# these at the working directory; with no .git in this dir the trust step
# is also where mise hashes the file for ToFU.
for f in mise.toml .tool-versions .ruby-version .nvmrc; do
    [ -f "\$f" ] || continue
    mise trust "\$f" 2>/dev/null || true
done

# \`mise install\` (no args) reads all configured files and installs every
# declared tool version. With multiple files it does the right thing.
mise install
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
