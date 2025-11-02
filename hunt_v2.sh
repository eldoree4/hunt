#!/bin/bash
#
# Hunt v2 - Production-ready wrapper
# Author: JFlow
# License: MIT - For Ethical Use Only
# Version: 2.1-prod
# Created: 2025-11-02
#
# Purpose:
# Production-oriented version of Hunt v2 with safer defaults, non-interactive modes,
# config file support, Docker friendliness, simplified dependency checks and logging.
#
# IMPORTANT: This tool is intended for authorized testing only. Use in isolated lab.
#

set -euo pipefail
IFS=$'\n\t'

# --------------------
# Config / Globals
# --------------------
PROGNAME=$(basename "$0")
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLS_DIR="${ROOT_DIR}/tools"
REPORT_DIR="${ROOT_DIR}/reports"
WORDLISTS_DIR="${ROOT_DIR}/wordlists"
CONFIG_FILE="${ROOT_DIR}/hunt_prod.conf"
LOG_FILE="${REPORT_DIR}/hunt_prod_${USER}_$(date +%Y%m%d_%H%M%S).log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Safer defaults
USER_AGENT="Hunt-Scanner/2.1-prod (JFlow)"
THREADS=5
DELAY=1
STEALTH_MODE=true
RATE_LIMIT_REQUESTS=50   # maximum requests per minute default
NON_INTERACTIVE=false

TARGET_URL=""
AUTH_TYPE="none"
COOKIE=""
AUTH_HEADER=""
JWT_TOKEN=""
OAUTH_CONFIG_FILE=""

# Ensure directories exist
mkdir -p "$TOOLS_DIR" "$REPORT_DIR" "$WORDLISTS_DIR"

# --------------------
# Logging
# --------------------
log() {
  local level="$1"; shift
  local msg="$*"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$LOG_FILE"
}

# --------------------
# Usage
# --------------------
usage() {
  cat <<EOF
$PROGNAME - Hunt v2 Production (Author: JFlow)

Usage:
  $PROGNAME -u <target_url> [options]

Options:
  -u <url>          Target URL (required)
  -c <config>       Path to config file (default: $CONFIG_FILE)
  -n                Non-interactive mode (useful for CI)
  -m <method>       Scan method: comprehensive|xss|api|directory
  -t <threads>      Number of threads (default: $THREADS)
  -d <delay>        Delay between requests in seconds (default: $DELAY)
  -s                Disable stealth mode
  -h                Show this help

Example:
  $PROGNAME -u https://example.com -n -m comprehensive

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
validate_url() {
  [[ $1 =~ ^https?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,} ]] || return 1
}

# --------------------
# Rate limiter (simple token bucket)
# --------------------
rate_limiter_init() {
  REQUESTS_LEFT="$RATE_LIMIT_REQUESTS"
  RATE_RESET_AT=$(( $(date +%s) + 60 ))
}

rate_limiter_check() {
  local now
  now=$(date +%s)
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
# HTTP request layer (safe)
# --------------------
make_request() {
  local url="$1"
  local method="${2:-GET}"
  local data="${3:-}"
  local extra_headers=("${@:4}")
  rate_limiter_check
  local headers=(-s -L -A "$USER_AGENT")
  for h in "${extra_headers[@]}"; do
    headers+=("-H" "$h")
  done
  if [ "$AUTH_TYPE" = "cookie" ] && [ -n "$COOKIE" ]; then
    headers+=("-H" "Cookie: $COOKIE")
  fi
  if [ "$AUTH_TYPE" = "header" ] && [ -n "$AUTH_HEADER" ]; then
    headers+=("-H" "$AUTH_HEADER")
  fi
  if [ "$method" = "GET" ]; then
    curl "${headers[@]}" "$url"
  else
    curl "${headers[@]}" -X "$method" -d "$data" "$url"
  fi
}

# --------------------
# Dependency check (non-invasive)
# --------------------
check_dependencies() {
  local missing=()
  for t in curl jq python3 node ffuf sqlmap nmap; do
    if ! command -v "$t" &>/dev/null; then
      missing+=("$t")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log WARN "Missing dependencies: ${missing[*]}"
    log WARN "You should install these in the container or host before running full scans."
  else
    log INFO "All recommended dependencies present."
  fi
}

# --------------------
# Headless renderer helper (calls node_render.js)
# --------------------
render_with_headless() {
  local url="$1"
  local out_file="$2"
  if command -v node &>/dev/null && [ -f "${TOOLS_DIR}/node_render.js" ]; then
    node "${TOOLS_DIR}/node_render.js" "$url" > "$out_file" || {
      log WARN "Headless render failed for $url; falling back to curl"
      make_request "$url" > "$out_file"
    }
  else
    log WARN "Headless renderer not available; using curl"
    make_request "$url" > "$out_file"
  fi
}

# --------------------
# Multi-step login helper
# --------------------
run_multi_login() {
  # calls multi_login.py to perform login and return cookie/header to use
  if command -v python3 &>/dev/null && [ -f "${TOOLS_DIR}/multi_login.py" ]; then
    python3 "${TOOLS_DIR}/multi_login.py" "$@" || {
      log WARN "Multi-step login helper failed or returned non-zero"
      return 1
    }
  else
    log WARN "Multi-login helper not available"
    return 1
  fi
}

# --------------------
# Simple scans (safe)
# --------------------
discover_api_endpoints() {
  local out="$REPORT_DIR/api_discovery_$TIMESTAMP.txt"
  log INFO "Discovering common API endpoints (safe checks)"
  local candidates=(api v1 v2 graphql rest json xml swagger openapi api-docs)
  for c in "${candidates[@]}"; do
    local u="${TARGET_URL%/}/$c"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$u" || echo 000)
    if [ "$code" != "404" ] && [ "$code" != "000" ]; then
      echo "$u|$code" >> "$out"
      log INFO "Found API candidate: $u (HTTP $code)"
    fi
  done
  log INFO "API discovery saved: $out"
}

run_xss_scan_extended() {
  local outdir="$1"
  mkdir -p "$outdir"
  local report="$outdir/xss_extended_$TIMESTAMP.txt"
  log INFO "Running non-invasive XSS checks (reflected) to $report"
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
# Main orchestration
# --------------------
main_run() {
  load_config
  check_dependencies
  rate_limiter_init

  if ! validate_url "$TARGET_URL"; then
    log ERROR "Invalid or missing target URL: $TARGET_URL"
    usage
    exit 2
  fi

  log INFO "Starting scan for $TARGET_URL (method=$SCAN_METHOD)"
  local scan_dir="$REPORT_DIR/scan_${TIMESTAMP}"
  mkdir -p "$scan_dir"

  case "${SCAN_METHOD:-comprehensive}" in
    comprehensive)
      discover_api_endpoints
      render_with_headless "$TARGET_URL" "$scan_dir/rendered_home.html"
      run_xss_scan_extended "$scan_dir"
      ;;
    xss) run_xss_scan_extended "$scan_dir" ;;
    api) discover_api_endpoints ;;
    directory) render_with_headless "$TARGET_URL" "$scan_dir/rendered_home.html";;
    *) log WARN "Unknown scan method: $SCAN_METHOD";;
  esac

  log INFO "Generating minimal summary"
  echo "Scan: $TIMESTAMP" > "$scan_dir/summary.txt"
  echo "Target: $TARGET_URL" >> "$scan_dir/summary.txt"
  echo "Method: ${SCAN_METHOD:-comprehensive}" >> "$scan_dir/summary.txt"
  echo "Reports: $(ls -1 "$scan_dir" | wc -l) files" >> "$scan_dir/summary.txt"

  log INFO "Scan completed. Reports stored under: $scan_dir"
}

# --------------------
# CLI parsing
# --------------------
while getopts ":u:c:nm:t:d:sh" opt; do
  case ${opt} in
    u) TARGET_URL="$OPTARG" ;;
    c) CONFIG_FILE="$OPTARG" ;;
    n) NON_INTERACTIVE=true ;;
    m) SCAN_METHOD="$OPTARG" ;;
    t) THREADS="$OPTARG" ;;
    d) DELAY="$OPTARG" ;;
    s) STEALTH_MODE=false ;;
    h) usage; exit 0 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done
shift $((OPTIND -1))

# Legal consent in interactive mode; non-interactive must have config flag LEGAL_CONSENT=yes
if [ "$NON_INTERACTIVE" = false ]; then
  echo "You must have written authorization to scan the target. Continue? (yes/no)"
  read -r consent
  if [ "$consent" != "yes" ]; then
    log ERROR "User did not confirm legal authorization. Exiting."
    exit 1
  fi
else
  # In non-interactive mode require env var or config variable LEGAL_CONSENT=yes
  if [ "${LEGAL_CONSENT:-}" != "yes" ] && [ "${LEGAL_CONSENT:-}" != "true" ]; then
    log ERROR "Non-interactive mode requires LEGAL_CONSENT=yes in config or environment."
    exit 1
  fi
fi

main_run

exit 0
