#!/usr/bin/env bash
# One-command benchmark runner.
#
# Usage:
#   ./run-benchmark.sh --tool nctl claude --policy-id cp_require_labels
#   ./run-benchmark.sh --tool nctl --containerized
#   ./run-benchmark.sh --report
#
# What it does:
#   1. Checks dependencies (docker, kyverno, python3, go)
#   2. Downloads + caches OpenAPI schemas for the Go validator
#   3. Builds the Go validator binary if needed
#   4. Downloads nctl binary for Docker builds if needed
#   5. Builds Docker images if needed (only when --containerized is used)
#   6. Syncs upstream kyverno policies if dataset is empty
#   7. Runs benchmark.py with all passed flags
#
# Cached artifacts (gitignored, download once):
#   .cache/schemas/       — Kyverno OpenAPI v3 schemas
#   .cache/nctl/          — nctl Linux binary for Docker builds
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$REPO_ROOT/.cache"
GO_VALIDATOR="$REPO_ROOT/validate-policy"
SCHEMA_DIR="$REPO_ROOT/cmd/validate-policy/schemas/openapi/v3"

# Kyverno version to fetch schemas for (should match go.mod)
KYVERNO_VERSION="v1.17.1"
KYVERNO_API_VERSION="v0.0.1-alpha.2"

# nctl download
NCTL_INSTALL_SCRIPT="https://downloads.nirmata.io/nctl/install.sh"
NCTL_CACHE="$CACHE_DIR/nctl"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

check_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not found. $2"
}

# ---------------------------------------------------------------------------
# 1. Dependency checks
# ---------------------------------------------------------------------------

check_deps() {
  check_cmd python3 "Install Python 3.9+"
  check_cmd go "Install Go 1.25+ (needed to build the policy validator)"

  # Docker only needed for --containerized
  if echo "$@" | grep -q -- "--containerized"; then
    check_cmd docker "Install Docker Desktop or OrbStack"
  fi

  # kyverno CLI optional but recommended
  if ! command -v kyverno >/dev/null 2>&1; then
    warn "kyverno CLI not found — functional tests will be skipped. Install: brew install kyverno"
  fi
}

# ---------------------------------------------------------------------------
# 2. Download + cache OpenAPI schemas
# ---------------------------------------------------------------------------

fetch_schemas() {
  if [ -d "$SCHEMA_DIR/apis/policies.kyverno.io" ] && [ -f "$SCHEMA_DIR/apis/policies.kyverno.io/v1beta1.json" ]; then
    return 0
  fi

  info "Downloading Kyverno OpenAPI schemas (cached after first run)..."
  mkdir -p "$CACHE_DIR/schemas"

  local api_ref="$KYVERNO_API_VERSION"
  local base_url="https://raw.githubusercontent.com/kyverno/api/${api_ref}"

  mkdir -p "$SCHEMA_DIR/apis/kyverno.io" "$SCHEMA_DIR/apis/policies.kyverno.io"

  # kyverno.io schemas (from kyverno/kyverno repo)
  local kyverno_base="https://raw.githubusercontent.com/kyverno/kyverno/${KYVERNO_VERSION}"
  for ver in v1 v2 v2beta1; do
    local dest="$SCHEMA_DIR/apis/kyverno.io/${ver}.json"
    if [ ! -f "$dest" ]; then
      # Schemas are generated — try the api repo first, fall back to cache
      if [ -f "$CACHE_DIR/schemas/kyverno.io-${ver}.json" ]; then
        cp "$CACHE_DIR/schemas/kyverno.io-${ver}.json" "$dest"
      else
        warn "Schema kyverno.io/${ver}.json not found in cache. Run 'make codegen-schema-openapi' in go-llm-apps or copy schemas manually."
      fi
    fi
  done

  # policies.kyverno.io schemas (from kyverno/api repo)
  for ver in v1alpha1 v1beta1 v1; do
    local dest="$SCHEMA_DIR/apis/policies.kyverno.io/${ver}.json"
    if [ ! -f "$dest" ]; then
      if [ -f "$CACHE_DIR/schemas/policies.kyverno.io-${ver}.json" ]; then
        cp "$CACHE_DIR/schemas/policies.kyverno.io-${ver}.json" "$dest"
      else
        warn "Schema policies.kyverno.io/${ver}.json not found in cache. Run 'make codegen-schema-openapi' in go-llm-apps or copy schemas manually."
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# 3. Build Go validator
# ---------------------------------------------------------------------------

build_go_validator() {
  if [ -f "$GO_VALIDATOR" ]; then
    return 0
  fi

  info "Building Go policy validator..."
  fetch_schemas
  (cd "$REPO_ROOT/cmd/validate-policy" && GOWORK=off go build -o "$GO_VALIDATOR" .)
  info "Built: $GO_VALIDATOR"
}

# ---------------------------------------------------------------------------
# 4. Download nctl for Docker builds
# ---------------------------------------------------------------------------

fetch_nctl() {
  local nctl_bin="$REPO_ROOT/docker/nctl"
  if [ -f "$nctl_bin" ]; then
    return 0
  fi

  # Check cache first
  if [ -f "$NCTL_CACHE/nctl" ]; then
    info "Using cached nctl binary"
    cp "$NCTL_CACHE/nctl" "$nctl_bin"
    return 0
  fi

  info "Downloading nctl binary for Docker builds..."
  mkdir -p "$NCTL_CACHE"

  # Download using the official install script into a temp dir, then extract
  local tmpdir
  tmpdir=$(mktemp -d)
  NCTL_INSTALL_DIR="$tmpdir" bash <(curl -fsSL "$NCTL_INSTALL_SCRIPT") 2>&1 | tail -5

  if [ -f "$tmpdir/nctl" ]; then
    cp "$tmpdir/nctl" "$NCTL_CACHE/nctl"
    cp "$tmpdir/nctl" "$nctl_bin"
    chmod +x "$nctl_bin"
    info "nctl cached at $NCTL_CACHE/nctl"
  else
    rm -rf "$tmpdir"
    die "Failed to download nctl. Install manually and place at docker/nctl"
  fi
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# 5. Build Docker images
# ---------------------------------------------------------------------------

build_docker_images() {
  if ! echo "$@" | grep -q -- "--containerized"; then
    return 0
  fi

  local needs_build=false
  for img in benchmark-base benchmark-nctl benchmark-claude benchmark-cursor; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      needs_build=true
      break
    fi
  done

  if [ "$needs_build" = false ]; then
    return 0
  fi

  info "Building Docker images..."
  fetch_nctl

  cd "$REPO_ROOT/docker"
  docker build -f Dockerfile.base -t benchmark-base . 2>&1 | tail -3
  docker build -f Dockerfile.nctl -t benchmark-nctl --build-arg NCTL_BIN=nctl . 2>&1 | tail -3
  docker build -f Dockerfile.claude -t benchmark-claude . 2>&1 | tail -3
  docker build -f Dockerfile.cursor -t benchmark-cursor . 2>&1 | tail -3
  cd "$REPO_ROOT"
  info "Docker images built."
}

# ---------------------------------------------------------------------------
# 6. Sync dataset
# ---------------------------------------------------------------------------

sync_dataset() {
  local policy_dir="$REPO_ROOT/dataset/imported/kyverno-policies"
  if [ -d "$policy_dir" ] && [ "$(ls "$policy_dir"/*.yaml 2>/dev/null | wc -l)" -gt 0 ]; then
    return 0
  fi

  info "Syncing upstream kyverno policies..."
  python3 "$REPO_ROOT/scripts/sync_kyverno_policies.py"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  echo ""
  echo "  Policy Conversion Benchmark"
  echo "  ==========================="
  echo ""

  # If just --report, skip builds
  if [ "$#" -eq 1 ] && [ "$1" = "--report" ]; then
    info "[1/1] Generating report..."
    python3 "$REPO_ROOT/benchmark.py" --report
    return
  fi

  info "[1/6] Checking dependencies..."
  check_deps "$@"

  info "[2/6] Building Go policy validator..."
  build_go_validator

  info "[3/6] Syncing upstream kyverno policies..."
  sync_dataset

  info "[4/6] Building Docker images..."
  build_docker_images "$@"

  info "[5/6] Running benchmark..."
  python3 "$REPO_ROOT/benchmark.py" "$@"

  info "[6/6] Generating report..."
  python3 "$REPO_ROOT/benchmark.py" --report

  echo ""
  echo "  Done."
  echo "  Dashboard: reports/output/dashboard.html"
  echo "  Markdown:  reports/output/report.md"
  echo "  Results:   results/"
  echo ""
}

main "$@"
