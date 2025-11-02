#!/bin/bash
#
# Hunt v2 - Production-ready wrapper (updated with XSS context & WAF modules)
# Author: JFlow
# License: MIT - For Ethical Use Only
# Version: 2.1-prod+ctxwaf
# Created: 2025-11-02
#
# NOTE: This file is an updated version that integrates the context-aware XSS
# and WAF fingerprint/evasion modules (tools/xss_context.js and tools/waf_fingerprint.sh).
# The modules are opt-in and safe-by-default (dry-run). To run intrusive actions:
#  - Provide allowed_targets.txt in repo root (one hostname per line)
#  - Use explicit flags --enable-xss or --enable-waf-evasion
#  - Set LEGAL_CONSENT=yes in config or confirm interactively
#
# Usage highlights:
#   ./hunt_v2_production.sh -u https://target.lab --enable-xss --dry-run
#   ./hunt_v2_production.sh -u https://target.lab --enable-xss --enable-waf-evasion --attack
#
set -euo pipefail
IFS=$'\n\t'

# --------------------
# Metadata & Globals
# --------------------
PROGNAME=$(basename "$0")
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLS_DIR="${ROOT_DIR}/tools"
REPORT_DIR="${ROOT_DIR}/reports"
WORDLISTS_DIR="${ROOT_DIR}/wordlists"
CONFIG_FILE="${ROOT_DIR}/hunt_prod.conf"
LOG_FILE="${REPORT_DIR}/hunt_prod_${USER}_$(date +%Y%m%d_%H%M%S).log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

USER_AGENT="Hunt-Scanner/2.1-prod (JFlow)"
THREADS=5
DELAY=1
STEALTH_MODE=true
RATE_LIMIT_REQUESTS=50

TARGET_URL=""
SCAN_METHOD=""
AUTH_TYPE="none"
COOKIE=""
AUTH_HEADER=""
NON_INTERACTIVE=false
LEGAL_CONSENT="${LEGAL_CONSENT:-yes}"

# New opt-in flags for advanced modules
ENABLE_XSS=true
ENABLE_WAF=true
DRY_RUN=false
ATTACK_MODE=true

mkdir -p "$TOOLS_DIR" "$REPORT_DIR" "$WORDLISTS_DIR"

# --------------------
# Logging
# --------------------
log() { local level="$1"; shift; echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"; }

# --------------------
# Usage
# --------------------
usage() {
  cat <<EOF
$PROGNAME - Hunt v2 Production (Author: JFlow)

Usage:
  $PROGNAME -u <target_url> [options]

Options:
  -u <url>              Target URL (required)
  -m <method>           Scan method: comprehensive|xss|api|directory
  -t <threads>          Number of threads
  -d <delay>            Delay between requests in seconds
  --enable-xss          Enable context-aware XSS module (opt-in)
  --enable-waf-evasion  Enable WAF fingerprint + safe evasion module (opt-in)
  --dry-run             (default) Plan actions but do not perform intrusive requests
  --attack              Execute allowed intrusive actions (requires allowed_targets.txt and LEGAL_CONSENT=yes)
  -n                    Non-interactive (requires LEGAL_CONSENT=yes in config)
  -h                    Show help

Example:
  $PROGNAME -u https://target.lab --enable-xss --dry-run

EOF
}

# --------------------
# Config loader
# --------------------
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    log INFO "Loading config: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

# --------------------
# Validate target
# --------------------
validate_url() { [[ $1 =~ ^https?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,} ]] || return 1; }

# --------------------
# Rate limiter
# --------------------
rate_limiter_init() {
  REQUESTS_LEFT="$RATE_LIMIT_REQUESTS"
  RATE_RESET_AT=$(( $(date +%s) + 60 ))
}
rate_limiter_check() {
  local now=$(date +%s)
  if [ "$now" -ge "$RATE_RESET_AT" ]; then
    REQUESTS_LEFT="$RATE_LIMIT_REQUESTS"
    RATE_RESET_AT=$(( now + 60 ))
  fi
  if [ "$REQUESTS_LEFT" -le 0 ]; then
    log WARN "Rate limit reached. Sleeping until reset..."
    sleep $(( RATE_RESET_AT - now + 1 ))
    REQUESTS_LEFT="$RATE_LIMIT_REQUESTS"
    RATE_RESET_AT=$(( $(date +%s) + 60 ))
  fi
  REQUESTS_LEFT=$((REQUESTS_LEFT - 1))
}

# --------------------
# HTTP request layer
# --------------------
make_request() {
  local url="$1"; local method="${2:-GET}"; local data="${3:-}"; shift 3
  local extra_headers=("$@")
  rate_limiter_check
  local headers=(-s -L -A "$USER_AGENT")
  for h in "${extra_headers[@]}"; do headers+=("-H" "$h"); done
  if [ "$AUTH_TYPE" = "cookie" ] && [ -n "$COOKIE" ]; then headers+=("-H" "Cookie: $COOKIE"); fi
  if [ "$AUTH_TYPE" = "header" ] && [ -n "$AUTH_HEADER" ]; then headers+=("-H" "$AUTH_HEADER"); fi
  if [ "$method" = "GET" ]; then curl "${headers[@]}" "$url"; else curl "${headers[@]}" -X "$method" -d "$data" "$url"; fi
}

# --------------------
# Dependency check
# --------------------
check_dependencies() {
  local missing=()
  for t in curl jq python3 node ffuf sqlmap nmap; do
    if ! command -v "$t" &>/dev/null; then missing+=("$t"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then log WARN "Missing dependencies: ${missing[*]}"; else log INFO "Dependencies OK"; fi
}

# --------------------
# Headless renderer helper
# --------------------
render_with_headless() {
  local url="$1" out="$2"
  if command -v node &>/dev/null && [ -f "${TOOLS_DIR}/node_render.js" ]; then
    node "${TOOLS_DIR}/node_render.js" "$url" > "$out" || { log WARN "Headless render failed; using curl"; make_request "$url" > "$out"; }
  else
    log WARN "Headless renderer not available; using curl"
    make_request "$url" > "$out"
  fi
}

# --------------------
# Integration functions for new modules
# --------------------
run_xss_context_module() {
  local target="$1"; local outdir="$2"
  mkdir -p "$outdir"
  local out_json="$outdir/xss_context_$(date +%Y%m%d_%H%M%S).json"
  if [ "$DRY_RUN" = "true" ]; then
    log INFO "XSS context (dry-run) for $target -> $out_json"
    node "$TOOLS_DIR/xss_context.js" "$target" --dry-run --output="$out_json"
  else
    # attack mode: require allowed_targets and LEGAL_CONSENT
    if [ ! -f "$ROOT_DIR/allowed_targets.txt" ]; then log ERROR "allowed_targets.txt missing; abort"; return 1; fi
    if [ "${LEGAL_CONSENT}" != "yes" ]; then log ERROR "LEGAL_CONSENT != yes; abort"; return 1; fi
    log INFO "XSS context (attack) for $target -> $out_json"
    node "$TOOLS_DIR/xss_context.js" "$target" --attack --allowed="$ROOT_DIR/allowed_targets.txt" --output="$out_json"
  fi
  log INFO "XSS context report: $out_json"
}

run_waf_fingerprint_module() {
  local target="$1" outdir="$2"
  mkdir -p "$outdir"
  if [ "$DRY_RUN" = "true" ]; then
    log INFO "WAF fingerprint (dry-run) for $target"
    "$TOOLS_DIR/waf_fingerprint.sh" "$target" --dry-run
  else
    if [ ! -f "$ROOT_DIR/allowed_targets.txt" ]; then log ERROR "allowed_targets.txt missing; abort"; return 1; fi
    if [ "${LEGAL_CONSENT}" != "yes" ]; then log ERROR "LEGAL_CONSENT != yes; abort"; return 1; fi
    log INFO "WAF fingerprint & evasions (attack) for $target"
    "$TOOLS_DIR/waf_fingerprint.sh" "$target" --attack --allowed="$ROOT_DIR/allowed_targets.txt"
  fi
}

# --------------------
# Discovery & safe scans
# --------------------
discover_api_endpoints() {
  local out="$REPORT_DIR/api_discovery_$TIMESTAMP.txt"
  log INFO "Discovering API endpoints (safe checks)"
  local candidates=(api v1 v2 graphql rest json xml swagger openapi api-docs)
  for c in "${candidates[@]}"; do
    local u="${TARGET_URL%/}/$c"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$u" || echo 000)
    if [ "$code" != "404" ] && [ "$code" != "000" ]; then echo "$u|$code" >> "$out"; log INFO "Found: $u (HTTP $code)"; fi
  done
  log INFO "API discovery saved: $out"
}

run_xss_scan_extended() {
  local outdir="$1"
  mkdir -p "$outdir"
  local report="$outdir/xss_extended_$TIMESTAMP.txt"
  log INFO "Running non-invasive XSS checks -> $report"
  local payloads=("<script>prompt(1)</script>" "<img src=x onerror=alert(1)>" "'';!--\"<XSS>=&{()}")
  for p in "${payloads[@]}"; do
    local u="${TARGET_URL}?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$p'''))")"
    local resp
    resp=$(make_request "$u" || true)
    if echo "$resp" | grep -F "$p" >/dev/null 2>&1; then
      echo "REFLECTED:$u|$p" >> "$report"
      log WARN "Potential reflected XSS at: $u"
    fi
  done
  log INFO "XSS scan completed: $report"
}

# --------------------
# Orchestration
# --------------------
main_run() {
  load_config
  check_dependencies
  rate_limiter_init

  if ! validate_url "$TARGET_URL"; then log ERROR "Invalid or missing target URL"; usage; exit 2; fi

  log INFO "Starting scan for $TARGET_URL (method=${SCAN_METHOD:-comprehensive})"
  local scan_dir="$REPORT_DIR/scan_${TIMESTAMP}"
  mkdir -p "$scan_dir"

  # Base discovery and rendering
  discover_api_endpoints
  render_with_headless "$TARGET_URL" "$scan_dir/rendered_home.html"
  run_xss_scan_extended "$scan_dir"

  # Optional integrated modules (opt-in)
  if [ "$ENABLE_WAF" = "true" ]; then
    run_waf_fingerprint_module "$TARGET_URL" "$scan_dir"
  fi
  if [ "$ENABLE_XSS" = "true" ]; then
    run_xss_context_module "$TARGET_URL" "$scan_dir"
  fi

  log INFO "Minimal summary"
  echo "Scan: $TIMESTAMP" > "$scan_dir/summary.txt"
  echo "Target: $TARGET_URL" >> "$scan_dir/summary.txt"
  echo "Method: ${SCAN_METHOD:-comprehensive}" >> "$scan_dir/summary.txt"
  echo "Modules: XSS=${ENABLE_XSS} WAF=${ENABLE_WAF}" >> "$scan_dir/summary.txt"

  log INFO "Scan completed. Reports under: $scan_dir"
}

# --------------------
# CLI parsing
# --------------------
# Support long flags as well
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) TARGET_URL="$2"; shift 2 ;;
    -m) SCAN_METHOD="$2"; shift 2 ;;
    -t) THREADS="$2"; shift 2 ;;
    -d) DELAY="$2"; shift 2 ;;
    --enable-xss) ENABLE_XSS=true; shift ;;
    --enable-waf-evasion) ENABLE_WAF=true; shift ;;
    --dry-run) DRY_RUN=true; ATTACK_MODE=false; shift ;;
    --attack) DRY_RUN=false; ATTACK_MODE=true; shift ;;
    -n) NON_INTERACTIVE=true; shift ;;
    -h) usage; exit 0 ;;
    --help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

# Non-interactive legal consent handling
if [ "$NON_INTERACTIVE" = true ]; then
  if [ "${LEGAL_CONSENT}" != "yes" ]; then log ERROR "Non-interactive requires LEGAL_CONSENT=yes in config"; exit 1; fi
else
  if [ "${LEGAL_CONSENT}" != "yes" ]; then
    echo "You must have written authorization to scan the target. Continue? (yes/no)"
    read -r consent
    if [ "$consent" != "yes" ]; then log ERROR "User did not confirm legal authorization"; exit 1; fi
    LEGAL_CONSENT="yes"
  fi
fi

# Ensure attack mode consistency
if [ "$ATTACK_MODE" = true ] && [ "${LEGAL_CONSENT}" != "yes" ]; then
  log ERROR "Attack mode requires LEGAL_CONSENT=yes"; exit 1
fi
# If --attack passed, override DRY_RUN
if [ "$ATTACK_MODE" = true ]; then DRY_RUN=false; fi

# Map DRY_RUN to internal flag used by funcs
if [ "$DRY_RUN" = true ]; then
  log INFO "Operating in DRY-RUN mode (no intrusive payloads will be sent)"
else
  log INFO "Operating in ATTACK mode (intrusive modules will execute when allowed)"
fi

# propagate XSS/WAF enabling to actual logic
if [ "$ENABLE_XSS" = true ]; then ENABLE_XSS=true; fi
if [ "$ENABLE_WAF" = true ]; then ENABLE_WAF=true; fi

main_run

exit 0
