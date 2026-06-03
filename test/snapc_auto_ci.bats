#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup
    CMD="$PROJECT_ROOT/plugins/snapc-auto-ci/commands/snapc-auto-ci.sh"
    cd "$BATS_TEST_TMPDIR"
    mkdir -p .github/workflows
}

# Sanity: skip the whole suite cleanly if python3 + yaml isn't around.
# The plugin's plugin.toml declares python3 as a host_dep but bats
# environments don't always have py3-yaml installed.
_has_pyyaml() {
    python3 -c 'import yaml' 2>/dev/null
}

@test "snapc-auto-ci: plugin.toml declares command-only with no triggers" {
    run grep -q 'commands *= *\["snapc-auto-ci"\]' "$PROJECT_ROOT/plugins/snapc-auto-ci/plugin.toml"
    assert_success
    run grep -q 'triggers *= *\[\]' "$PROJECT_ROOT/plugins/snapc-auto-ci/plugin.toml"
    assert_success
    run grep -q 'host_deps *= *\["python3"\]' "$PROJECT_ROOT/plugins/snapc-auto-ci/plugin.toml"
    assert_success
}

@test "snapc-auto-ci: --workflow path missing services: errors cleanly" {
    if ! _has_pyyaml; then skip "pyyaml not installed"; fi
    cat > .github/workflows/empty.yml <<'YAML'
name: empty
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
    run env RL_LIB_DIR="$LIB_DIR" bash "$CMD" --workflow .github/workflows/empty.yml --print
    [ "$status" -ne 0 ]
    [[ "$output" == *"no job with a services: block"* ]]
}

@test "snapc-auto-ci: ruby/setup-ruby + pg services -> plugins=[ruby] + synth compose" {
    if ! _has_pyyaml; then skip "pyyaml not installed"; fi
    cat > .github/workflows/ci.yml <<'YAML'
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_PASSWORD: postgres }
        options: --health-cmd "pg_isready -U postgres"
    steps:
      - uses: actions/checkout@v5
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: '3.4' }
      - run: bundle exec rake test
YAML
    run env RL_LIB_DIR="$LIB_DIR" bash "$CMD" --print
    assert_success
    [[ "$output" == *'"ruby"'* ]]
    [[ "$output" == *'"docker-engine"'* ]]
    [[ "$output" == *'"docker-compose"'* ]]
    [[ "$output" == *'services = ["postgres"]'* ]]
    [[ "$output" == *'postgres:16'* ]]
    [[ "$output" == *'pg_isready -U postgres'* ]]
}

@test "snapc-auto-ci: actions/setup-python -> mise-base + python-runtime + uv default" {
    if ! _has_pyyaml; then skip "pyyaml not installed"; fi
    cat > .github/workflows/ci.yml <<'YAML'
name: CI
on: [push]
jobs:
  test:
    services:
      db: { image: postgres:16 }
    steps:
      - uses: actions/setup-python@v5
      - run: pytest
YAML
    run env RL_LIB_DIR="$LIB_DIR" bash "$CMD" --print
    assert_success
    [[ "$output" == *'"mise-base"'* ]]
    [[ "$output" == *'"python-runtime"'* ]]
    [[ "$output" == *'"uv"'* ]]
    [[ "$output" != *'"poetry"'* ]]
}

@test "snapc-auto-ci: poetry.lock present -> poetry instead of uv" {
    if ! _has_pyyaml; then skip "pyyaml not installed"; fi
    cat > .github/workflows/ci.yml <<'YAML'
name: CI
on: [push]
jobs:
  test:
    services:
      db: { image: postgres:16 }
    steps:
      - uses: actions/setup-python@v5
      - run: pytest
YAML
    touch poetry.lock
    run env RL_LIB_DIR="$LIB_DIR" bash "$CMD" --print
    assert_success
    [[ "$output" == *'"poetry"'* ]]
    [[ "$output" != *'"uv"'* ]]
}

@test "snapc-auto-ci: actions/setup-node default -> npm; with pnpm-lock.yaml -> pnpm" {
    if ! _has_pyyaml; then skip "pyyaml not installed"; fi
    cat > .github/workflows/ci.yml <<'YAML'
name: CI
on: [push]
jobs:
  test:
    services:
      redis: { image: redis:7 }
    steps:
      - uses: actions/setup-node@v4
      - run: npm test
YAML
    run env RL_LIB_DIR="$LIB_DIR" bash "$CMD" --print
    assert_success
    [[ "$output" == *'"npm"'* ]]
    [[ "$output" != *'"pnpm"'* ]]
    touch pnpm-lock.yaml
    run env RL_LIB_DIR="$LIB_DIR" bash "$CMD" --print
    assert_success
    [[ "$output" == *'"pnpm"'* ]]
}

@test "snapc-auto-ci: --write refuses overwriting existing snapcompose.toml unless --force" {
    if ! _has_pyyaml; then skip "pyyaml not installed"; fi
    cat > .github/workflows/ci.yml <<'YAML'
name: CI
on: [push]
jobs:
  test:
    services:
      db: { image: postgres:16 }
    steps: [{ uses: actions/setup-python@v5 }]
YAML
    echo "EXISTING" > snapcompose.toml
    run env RL_LIB_DIR="$LIB_DIR" bash "$CMD" --write
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
    [ "$(cat snapcompose.toml)" = "EXISTING" ]

    run env RL_LIB_DIR="$LIB_DIR" bash "$CMD" --write --force
    assert_success
    run grep -q '"docker-compose"' snapcompose.toml
    assert_success
    [ -f .snapcompose/auto-ci/docker-compose.synthesised.yml ]
}
