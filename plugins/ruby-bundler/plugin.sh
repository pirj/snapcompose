#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"

# Skip this layer entirely when there's no Gemfile.lock — saves ~5-7 s
# of rebase+boot+stop cycle the framework would otherwise run around a
# no-op snapshot_build.
snapshot_should_skip() {
    [ -f Gemfile.lock ] || echo "skip"
}

# Snapshot key = SHA256 of Gemfile.lock plus version markers that affect
# what bundler installs (Ruby version, bundler version). `|| true` keeps
# missing optional files from tripping the surrounding `set -e`.
snapshot_key() {
    {
        cat Gemfile.lock      2>/dev/null || true
        cat .ruby-version     2>/dev/null || true
        cat .bundler-version  2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

# Run `bundle install` inside the guest as the rlock user. mise (a dep
# of this plugin) has already installed Ruby + bundler if declared in
# the project's tool-version files. Falls back to system bundler if
# mise isn't configured for Ruby — `bundle install` will pull the gem
# if needed.
snapshot_build() {
    local vm="$1"
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    if [ ! -f Gemfile.lock ]; then
        info "ruby-bundler: no Gemfile.lock in project root, nothing to install"
        return 0
    fi

    # The project worktree (with Gemfile.lock) lives at
    # $SNAPC_VM_PROJECT_DIR (F1: monorepo-aware). `bundle install` runs
    # there so vendor/bundle lands alongside Gemfile.lock.
    aq exec "$vm" sh <<SH
set -eu
# Bundler builds native extensions; make sure the toolchain is present.
# This is incremental-friendly — apk add is a no-op if already installed.
apk add build-base libffi-dev openssl-dev readline-dev yaml-dev zlib-dev

su -l rlock -c "bash -l -s" <<RLOCK
set -eu
# mise must be on PATH — this plugin declares deps = ["mise"], so a
# missing mise here is a regression upstream, not a runtime fallback
# case. Fail loudly instead of silently using system Ruby (which would
# install gems against the wrong Ruby version).
eval "\$(mise activate bash)"
cd "$vm_project_dir"

# Bundler must come from the mise-managed Ruby. If bundle isn't
# resolvable, the project's Gemfile probably needs an explicit bundler
# version pin via .bundler-version or Gemfile's gem "bundler". Fail
# loudly so the user sees the actual cause rather than a phantom
# system-bundler success.
command -v bundle >/dev/null 2>&1

# bundle config set --local path vendor/bundle keeps gems in-tree so
# the cache layer captures them. --jobs=4 parallelises downloads; --retry
# tolerates transient network blips during the initial install.
bundle config set --local path vendor/bundle
bundle install --jobs=4 --retry=3
RLOCK
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
