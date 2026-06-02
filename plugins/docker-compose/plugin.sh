#!/usr/bin/env bash
set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/toml.sh"

# Resolve the compose file the project actually wants us to use.
# Priority:
#   1. `[docker-compose] file = "..."` in snapcompose.toml — projects
#      that ship multiple compose files (dev / staging / CI) name the
#      CI one explicitly. This is the OSS-Rails adoption path (22 of
#      the surveyed 150 projects ship a dev compose with `build:`
#      that doesn't match the CI workload).
#   2. docker-compose.yml at project root.
#   3. docker-compose.yaml at project root.
#
# Prints the basename; empty if none match. The plugin's snapshot_key
# and snapshot_build both consult this resolver so they stay in sync.
_resolve_compose_file() {
    local override=""
    if [[ -f snapcompose.toml ]]; then
        override=$(toml_get_in_section snapcompose.toml "docker-compose" "file" 2>/dev/null) || true
    fi
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi
    if [[ -f docker-compose.yml ]]; then
        printf '%s' "docker-compose.yml"; return 0
    fi
    if [[ -f docker-compose.yaml ]]; then
        printf '%s' "docker-compose.yaml"; return 0
    fi
    return 0
}

# Resolve the optional [docker-compose] services = [...] filter from
# snapcompose.toml. When set, only the named services are brought up
# (via `docker compose up -d <svc1> <svc2>`). Useful when the project's
# compose file ships extra services (app builds, sidecars) that CI
# doesn't need — let the plugin pin "what CI actually warms" without
# editing the compose file itself.
#
# Prints one service per line; empty output when not configured.
_resolve_services_filter() {
    if [[ -f snapcompose.toml ]]; then
        toml_get_array_in_section snapcompose.toml "docker-compose" "services" 2>/dev/null || true
    fi
}

# Hash every file that influences the warm state.
# When `[docker-compose] file = "..."` is set, the override path is
# hashed in addition to the canonical filenames — distinct override
# values must produce distinct keys, but a project that has both an
# override and a canonical-named file shouldn't accidentally collide
# with one that only has the canonical.
# When `[docker-compose] services = [...]` is set, the filter list is
# hashed too so that bringing up a different subset of the compose
# stack produces a different snapshot — the warm state is genuinely
# different.
snapshot_key() {
    local override
    override=$(_resolve_compose_file)
    {
        local f
        for f in Dockerfile docker-compose.yml docker-compose.yaml \
                 docker-compose.override.yml docker-compose.override.yaml \
                 .dockerignore; do
            if [[ -f "$f" ]]; then
                echo "=== $f ==="
                cat "$f"
            fi
        done
        # Include the override file if it's outside the canonical list.
        if [[ -n "$override" && -f "$override" ]]; then
            case "$override" in
                docker-compose.yml|docker-compose.yaml| \
                docker-compose.override.yml|docker-compose.override.yaml) ;;
                *)
                    echo "=== override:$override ==="
                    cat "$override"
                    ;;
            esac
        fi
        # Include the services filter if set. The list is preserved in
        # declaration order so reordering produces the same key only if
        # the result set is identical (TOML arrays are ordered).
        local filter_line
        filter_line=$(_resolve_services_filter | tr '\n' ' ' | sed 's/ *$//')
        if [[ -n "$filter_line" ]]; then
            echo "=== services-filter ==="
            printf '%s\n' "$filter_line"
        fi
    } | sha256sum | cut -d' ' -f1
}

snapshot_build() {
    local vm="$1"

    # F1 — subdir-as-project. snapc-run exports SNAPC_VM_PROJECT_DIR
    # to the directory inside the VM where THIS snapcompose project's
    # files should live (e.g. /home/rlock/repo/services/main for a
    # monorepo subproject). Falls back to /home/rlock/repo for single-
    # app fixtures.
    #
    # F3 — source is delivered by the framework's auto-push at the
    # first cache-miss boundary, before this snapshot_build runs. The
    # Dockerfile + docker-compose.yml are tracked in git alongside the
    # rest of the source; no per-file scp loop is needed.
    local vm_project_dir="${SNAPC_VM_PROJECT_DIR:-/home/rlock/repo}"

    # Resolve the compose file on the host (snapcompose.toml lives
    # there) and pass it through to the guest's `docker compose` calls
    # as -f <file>. When no override is configured, this is empty and
    # docker compose falls back to its own discovery.
    local compose_file
    compose_file=$(_resolve_compose_file)
    local compose_flag=""
    if [[ -n "$compose_file" ]]; then
        compose_flag="-f $compose_file"
    fi

    # Resolve the optional services filter. The list is passed to
    # `docker compose up -d` as positional args, which restricts the
    # up to those services + their depends_on. Empty when not set.
    local services_filter
    services_filter=$(_resolve_services_filter | tr '\n' ' ' | sed 's/ *$//')

    aq exec "$vm" sh <<SH
set -eu
command -v jq >/dev/null 2>&1 || apk add jq
cd "$vm_project_dir"
docker compose ${compose_flag} build ${services_filter}
docker compose ${compose_flag} up -d ${services_filter}

# Wait up to 5 minutes for all (filtered) services to be running.
# Services with a declared healthcheck must report Health == "healthy";
# services without (empty/null Health) are considered ready as soon as
# State == "running".
for i in \$(seq 1 60); do
    pending=\$(docker compose ${compose_flag} ps ${services_filter} --format json | \\
        jq -s '[.[] | select(.State != "running" or .Health == "starting" or .Health == "unhealthy")] | length')
    [ "\$pending" = "0" ] && exit 0
    sleep 5
done

echo "compose services failed to become healthy within 5 minutes:" >&2
docker compose ${compose_flag} ps ${services_filter} >&2
docker compose ${compose_flag} logs --tail=50 ${services_filter} >&2
exit 1
SH
}

if declare -f "$1" > /dev/null 2>&1; then
    "$1" "${@:2}"
fi
