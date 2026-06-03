#!/usr/bin/env bash
# snapc auto-ci — read .github/workflows/*.yml services: blocks +
# setup-<lang> actions, write a snapcompose.toml + synthesised
# docker-compose file under .snapcompose/auto-ci/ that drops in
# without touching the project's existing dev compose.
#
# Designed for the OSS-Rails / OSS-Python / OSS-Node outreach
# pattern (see meta/gtm-playbook.md "Expand beyond Rails"). The
# 51% of OSS GH-Actions projects that ship a `services:` block
# (per `meta/research-2026-05-30-rails-oss-ci-survey.md` for the
# Rails subset; ecosystem-wide surveys forthcoming) can adopt
# snapcompose with one command + one new workflow file, no
# `snapcompose.toml` author burden.

set -euo pipefail
source "${RL_LIB_DIR}/ui.sh"
source "${RL_LIB_DIR}/util.sh"

usage() {
    cat <<USAGE
Usage: snapc auto-ci [--workflow <file>] [--print|--write] [--force]

  --workflow <path>   Specific .github/workflows/<file>.yml to read.
                      Defaults to the first workflow whose services:
                      block has any entries.
  --print             Write the generated snapcompose.toml + synth
                      compose to stdout instead of disk.
  --write             Write to disk (default). Generates:
                        snapcompose.toml
                        .snapcompose/auto-ci/docker-compose.synthesised.yml
                      Refuses to overwrite an existing snapcompose.toml
                      unless --force is also given.
  --force             Overwrite an existing snapcompose.toml.

Detection rules:
  * services: entries become docker-compose services in the
    synthesised compose file (and pinned via the [docker-compose]
    file= / services= override in snapcompose.toml).
  * actions/setup-ruby@*    → adds "ruby" to plugins=[...].
  * actions/setup-python@*  → adds mise-base + python-runtime + uv
                              (or poetry if poetry.lock exists).
  * actions/setup-node@*    → adds mise-base + nodejs-runtime + npm
                              (or pnpm if pnpm-lock.yaml exists).
  * actions/setup-go@*      → adds mise-base + go-runtime.
USAGE
}

WORKFLOW=""
MODE="write"
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workflow) WORKFLOW="$2"; shift 2 ;;
        --workflow=*) WORKFLOW="${1#--workflow=}"; shift ;;
        --print) MODE="print"; shift ;;
        --write) MODE="write"; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) stderr "Unknown flag: $1"; usage; exit 2 ;;
    esac
done

if [[ -z "$WORKFLOW" ]]; then
    shopt -s nullglob
    for f in .github/workflows/*.yml .github/workflows/*.yaml; do
        if grep -qE '^[[:space:]]+services:' "$f" 2>/dev/null; then
            WORKFLOW="$f"
            break
        fi
    done
    shopt -u nullglob
fi

if [[ -z "$WORKFLOW" ]] || [[ ! -f "$WORKFLOW" ]]; then
    die "No workflow with a services: block found under .github/workflows/. Pass --workflow <path> to specify one."
fi

info "Reading $WORKFLOW"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

python3 - "$WORKFLOW" > "$TMPDIR/out" <<'PY'
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: python3 yaml module not installed (apk add py3-yaml / pip install pyyaml).", file=sys.stderr)
    sys.exit(1)

workflow_path = Path(sys.argv[1])
project_root = Path.cwd()
doc = yaml.safe_load(workflow_path.read_text())

services = None
chosen_job = None
for job_name, job in (doc.get("jobs") or {}).items():
    if isinstance(job, dict) and job.get("services"):
        services = job["services"]
        chosen_job = job
        break
if not services:
    print(f"ERROR: {workflow_path} has no job with a services: block.", file=sys.stderr)
    sys.exit(1)

plugins = ["docker-engine", "docker-compose"]
# Match both "actions/setup-<lang>" (the GH org's actions) and
# "<lang>/setup-<lang>" (the language org's). Real-world dominance:
#   * ruby/setup-ruby (NOT actions/setup-ruby — deprecated)
#   * actions/setup-python (no python-org alternative)
#   * actions/setup-node (no node-org alternative)
#   * actions/setup-go (no go-org alternative)
SETUP_RE = re.compile(r"^(?:actions|ruby|python|nodejs|go)/setup-(ruby|python|node|go)(?:@|$)")
for step in (chosen_job.get("steps") or []):
    uses = (step.get("uses") or "")
    m = SETUP_RE.match(uses)
    if not m:
        continue
    lang = m.group(1)
    if lang == "ruby":
        if "ruby" not in plugins:
            plugins.append("ruby")
    elif lang == "python":
        for p in ("mise-base", "python-runtime"):
            if p not in plugins:
                plugins.append(p)
        installer = "poetry" if (project_root / "poetry.lock").exists() else "uv"
        if installer not in plugins:
            plugins.append(installer)
    elif lang == "node":
        for p in ("mise-base", "nodejs-runtime"):
            if p not in plugins:
                plugins.append(p)
        installer = "pnpm" if (project_root / "pnpm-lock.yaml").exists() else "npm"
        if installer not in plugins:
            plugins.append(installer)
    elif lang == "go":
        for p in ("mise-base", "go-runtime"):
            if p not in plugins:
                plugins.append(p)

compose = {"services": {}}
for name, svc in services.items():
    if svc is None:
        continue
    if not isinstance(svc, dict):
        compose["services"][name] = {"image": str(svc)}
        continue
    out = {}
    if "image" in svc:
        out["image"] = svc["image"]
    env = svc.get("env")
    if env:
        if isinstance(env, dict):
            out["environment"] = {str(k): str(v) for k, v in env.items()}
        elif isinstance(env, list):
            out["environment"] = [str(e) for e in env]
    if svc.get("ports"):
        out["ports"] = [str(p) for p in svc["ports"]]
    if svc.get("volumes"):
        out["volumes"] = [str(v) for v in svc["volumes"]]
    opts = svc.get("options", "") or ""
    m = re.search(r'--health-cmd[ =](["\']?)(.*?)\1(?:\s|$)', opts)
    if m:
        out["healthcheck"] = {
            "test": ["CMD-SHELL", m.group(2)],
            "interval": "2s",
            "timeout": "3s",
            "retries": 30,
        }
    compose["services"][name] = out

service_names = sorted(compose["services"].keys())

lines = []
lines.append("# Generated by `snapc auto-ci` — re-run if your")
lines.append(f"# .github/workflows/{workflow_path.name} services: block changes.")
lines.append("")
lines.append("plugins = [")
for p in plugins:
    lines.append(f'  "{p}",')
lines.append("]")
lines.append("")
lines.append("[docker-compose]")
lines.append('file = ".snapcompose/auto-ci/docker-compose.synthesised.yml"')
if service_names:
    items = ", ".join(f'"{s}"' for s in service_names)
    lines.append(f"services = [{items}]")
lines.append("")
lines.append("[memory]")
lines.append('size = "4G"')
lines.append("")
lines.append("[disk]")
lines.append('size = "8G"')

compose_yaml = yaml.safe_dump(compose, sort_keys=False, default_flow_style=False)

print("=== snapcompose.toml ===")
print("\n".join(lines))
print("=== .snapcompose/auto-ci/docker-compose.synthesised.yml ===")
print(compose_yaml.rstrip())
PY

mapfile -t LINES < "$TMPDIR/out"

declare -A FILES
current=""
buf=""
flush() {
    if [[ -n "$current" ]]; then
        FILES["$current"]="$buf"
    fi
    buf=""
}
for line in "${LINES[@]}"; do
    if [[ "$line" =~ ^===\ (.+)\ ===$ ]]; then
        flush
        current="${BASH_REMATCH[1]}"
    else
        buf+="$line"$'\n'
    fi
done
flush

if [[ "$MODE" == "print" ]]; then
    for path in "${!FILES[@]}"; do
        echo "# === $path ==="
        printf '%s' "${FILES[$path]}"
        echo
    done
    exit 0
fi

if [[ -f snapcompose.toml ]] && [[ "$FORCE" -ne 1 ]]; then
    die "snapcompose.toml already exists. Pass --force to overwrite, or --print to inspect what would be written."
fi

mkdir -p .snapcompose/auto-ci
printf '%s' "${FILES[snapcompose.toml]}" > snapcompose.toml
printf '%s' "${FILES['.snapcompose/auto-ci/docker-compose.synthesised.yml']}" \
    > .snapcompose/auto-ci/docker-compose.synthesised.yml

info "Wrote snapcompose.toml ($(wc -l < snapcompose.toml) lines)"
info "Wrote .snapcompose/auto-ci/docker-compose.synthesised.yml ($(wc -l < .snapcompose/auto-ci/docker-compose.synthesised.yml) lines)"
info "Next: add .github/workflows/snapcompose-ci.yml invoking pirj/setup-snapcompose@v3."
