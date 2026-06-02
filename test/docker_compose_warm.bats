#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker-compose"
    cd "$BATS_TEST_TMPDIR"
}

@test "docker-compose plugin declares cached live snapshot with 4G memory + deps on docker-engine" {
    run grep -q '^\[snapshot\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    # Hard dep on docker-engine (dockerd is required to run any compose
    # workload). docker-registry-cache used to live here too; it's now
    # an opt-in optimisation that users add explicitly to avoid the
    # host `registry` binary becoming a hard install requirement.
    run grep -q 'deps *= *\["docker-engine"\]' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'strategy *= *"cached"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'kind *= *"live"' "$PLUGIN_DIR/plugin.toml"
    assert_success
    run grep -q 'memory *= *"4G"' "$PLUGIN_DIR/plugin.toml"
    assert_success
}

@test "docker-compose snapshot_key hashes Dockerfile + compose + .dockerignore" {
    cat > Dockerfile <<EOF
FROM alpine
EOF
    cat > docker-compose.yml <<EOF
services:
  db: {image: postgres:16}
EOF
    cat > .dockerignore <<EOF
*.log
EOF
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]

    echo "FROM debian" > Dockerfile
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" != "$k2" ]
}

@test "docker-compose snapshot_key is stable when files unchanged" {
    echo "FROM alpine" > Dockerfile
    local k1 k2
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" = "$k2" ]
}

# --- C1: [docker-compose] file = "..." override ---

@test "docker-compose snapshot_key incorporates the [docker-compose] file override" {
    cat > docker-compose.ci.yml <<EOF
services:
  db: {image: postgres:16}
EOF
    cat > snapcompose.toml <<EOF
[docker-compose]
file = "docker-compose.ci.yml"
EOF
    local k_override
    k_override=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    rm snapcompose.toml
    local k_default
    k_default=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    [ "$k_override" != "$k_default" ]
}

@test "docker-compose snapshot_key changes when override file content changes" {
    cat > snapcompose.toml <<EOF
[docker-compose]
file = "docker-compose.ci.yml"
EOF
    cat > docker-compose.ci.yml <<EOF
services:
  db: {image: postgres:16}
EOF
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    cat > docker-compose.ci.yml <<EOF
services:
  db: {image: postgres:17}
EOF
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    [ "$k1" != "$k2" ]
}

@test "docker-compose plugin falls back to docker-compose.yml when override absent" {
    cat > docker-compose.yml <<EOF
services:
  db: {image: postgres:16}
EOF
    # No snapcompose.toml — should hash docker-compose.yml as before.
    local k1
    k1=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ -n "$k1" ]

    # Adding an empty [docker-compose] section (no `file =` key) should
    # not change the key — empty override means use the canonical.
    cat > snapcompose.toml <<EOF
[docker-compose]
EOF
    local k2
    k2=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)
    [ "$k1" = "$k2" ]
}

# --- C2: [docker-compose] services = [...] filter ---

@test "docker-compose snapshot_key incorporates the services filter" {
    cat > docker-compose.yml <<EOF
services:
  db: {image: postgres:16}
  redis: {image: redis:7}
  app: {image: ruby:3.4}
EOF
    local k_no_filter
    k_no_filter=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    cat > snapcompose.toml <<EOF
[docker-compose]
services = ["db", "redis"]
EOF
    local k_filtered
    k_filtered=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    [ "$k_no_filter" != "$k_filtered" ]
}

@test "docker-compose snapshot_key changes when filter contents change" {
    cat > docker-compose.yml <<EOF
services:
  db: {image: postgres:16}
  redis: {image: redis:7}
EOF
    cat > snapcompose.toml <<EOF
[docker-compose]
services = ["db"]
EOF
    local k_db
    k_db=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    cat > snapcompose.toml <<EOF
[docker-compose]
services = ["db", "redis"]
EOF
    local k_both
    k_both=$(RL_LIB_DIR="$LIB_DIR" bash "$PLUGIN_DIR/plugin.sh" snapshot_key)

    [ "$k_db" != "$k_both" ]
}
