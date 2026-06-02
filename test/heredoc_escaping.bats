#!/usr/bin/env bats

# Regression coverage for the triple-escape (`\\\$`) pattern used by
# runtime + lang-installer plugins around nested unquoted heredocs.
#
# The shape is:
#   aq exec "$vm" sh <<SH       # outer (unquoted) — expands once
#   ...
#   su -l rlock -c "bash -l -s" <<RLOCK   # inner (unquoted) — expands once
#   ...
#   eval "\\\$(mise activate bash)"
#   for f in mise.toml .tool-versions ; do
#       [ -f "\\\$f" ] || continue
#   done
#   RLOCK
#   SH
#
# After the outer SH expansion, the script that hits `aq exec` should
# contain `\$f` and `\$(mise activate bash)` — backslash + $. After
# the guest re-evaluates that under the inner RLOCK heredoc, the
# backslash is consumed and `bash -l -s` sees literal `$f`.
#
# Phase 2 of the snapcompose-benchmark walking-skeleton hit a regression
# where single-escape (`\$f`) survived the outer expansion intact but
# the inner RLOCK heredoc then re-evaluated `$f` as an unset parameter
# (set -u inside the rlock-user script) and the per-layer build crashed
# with "f: parameter not set" or "command: unbound variable".
#
# These tests freeze the current behaviour BEFORE any de-escaping
# refactor (v0.4 plugin protocol bump). They assert on the captured
# stdin to a stub `aq exec`, i.e. exactly what the runner would ship
# to the guest's `sh -s` after one round of expansion.

setup() {
    load 'test_helper/common'
    _common_setup

    # Stub `aq` that captures the post-outer-heredoc stdin to a file
    # and writes nothing back. Only `aq exec ...` is intercepted; any
    # other subcommand exits 0 as a no-op (none are reached in this
    # path, but defensive).
    STUB_BIN="$BATS_TEST_TMPDIR/stub_bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/aq" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    exec) cat > "$AQ_CAPTURE_FILE" ;;
    *)    : ;;
esac
STUB
    chmod +x "$STUB_BIN/aq"
    export PATH="$STUB_BIN:$PATH"
    export AQ_CAPTURE_FILE="$BATS_TEST_TMPDIR/captured.sh"
    export SNAPC_VM_PROJECT_DIR="/home/rlock/repo"
    cd "$BATS_TEST_TMPDIR"
}

# ----------------- ruby-runtime -----------------

@test "ruby-runtime snapshot_build: outer-heredoc expansion preserves backslash-dollar for inner RLOCK" {
    PLUGIN_DIR="$PROJECT_ROOT/plugins/ruby-runtime"
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" \
        snapshot_build test-vm
    assert_success
    [ -f "$AQ_CAPTURE_FILE" ]

    # `mise activate bash` — must survive as backslash-dollar in the
    # captured (post-outer-expansion) script so the inner RLOCK
    # heredoc strips one backslash and the guest `bash -l -s` sees
    # literal `$(mise activate bash)`.
    run grep -F 'eval "\$(mise activate bash)"' "$AQ_CAPTURE_FILE"
    assert_success

    # `$f` loop variable — same shape.
    run grep -F '[ -f "\$f" ] || continue' "$AQ_CAPTURE_FILE"
    assert_success
    run grep -F 'mise trust "\$f"' "$AQ_CAPTURE_FILE"
    assert_success

    # `$vm_project_dir` MUST have been expanded (it's a plugin-side
    # bash var that injects the project path into the heredoc).
    run grep -F 'cd "/home/rlock/repo"' "$AQ_CAPTURE_FILE"
    assert_success

    # Negative: a single `$f` (no backslash) would mean the outer
    # heredoc already consumed both escape passes — that's the bug.
    refute_line --regexp '^[^\]\$f'
}

# ----------------- ruby-bundler -----------------

@test "ruby-bundler snapshot_build: outer-heredoc expansion preserves backslash-dollar mise activate" {
    PLUGIN_DIR="$PROJECT_ROOT/plugins/ruby-bundler"
    # ruby-bundler short-circuits without a Gemfile.lock and never hits
    # the aq exec path. Drop a stub.
    : > Gemfile.lock
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" \
        snapshot_build test-vm
    assert_success
    [ -f "$AQ_CAPTURE_FILE" ]

    run grep -F 'eval "\$(mise activate bash)"' "$AQ_CAPTURE_FILE"
    assert_success
    run grep -F 'cd "/home/rlock/repo"' "$AQ_CAPTURE_FILE"
    assert_success
}

# ----------------- go-runtime (one representative of the rest) -----------------

@test "go-runtime snapshot_build: same triple-escape pattern as ruby-runtime" {
    PLUGIN_DIR="$PROJECT_ROOT/plugins/go-runtime"
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" \
        snapshot_build test-vm
    assert_success
    [ -f "$AQ_CAPTURE_FILE" ]

    run grep -F 'eval "\$(mise activate bash)"' "$AQ_CAPTURE_FILE"
    assert_success
    run grep -F '[ -f "\$f" ] || continue' "$AQ_CAPTURE_FILE"
    assert_success
}

# ----------------- npm (dep-installer) -----------------

@test "npm snapshot_build: outer-heredoc expansion preserves backslash-dollar mise activate" {
    PLUGIN_DIR="$PROJECT_ROOT/plugins/npm"
    : > package-lock.json
    run env RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" \
        snapshot_build test-vm
    assert_success
    [ -f "$AQ_CAPTURE_FILE" ]

    run grep -F 'eval "\$(mise activate bash)"' "$AQ_CAPTURE_FILE"
    assert_success
}
