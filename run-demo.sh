#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════════
# FlashOrder Platform – Master Demo Script
# ═════════════════════════════════════════════════════════════════════════════
#
# USAGE:
#   ./run-demo.sh [command]
#
# COMMANDS:
#   start      Start microservices stack (docker compose up)
#   smoke      Smoke test against microservices (5 VUs × 30 s)
#   load       Load test microservices AND monolith, then compare
#   stress     Stress test microservices (find breaking point)
#   compare    Print side-by-side ASCII comparison table
#   stop       Tear down all stacks
#   full-demo  Automated end-to-end demo (start → smoke → load → compare → stop)
#   help       Show this message
#
# PREREQUISITES:
#   docker, docker compose (v2), k6, curl, jq
#   Optional: python3 + matplotlib for PNG chart (compare step)
#
# ═════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_MS="docker-compose.yaml"
COMPOSE_MONO="docker-compose.monolith.yml"
RESULTS_DIR="results"
K6_DIR="k6"
SCRIPTS_DIR="scripts"

MS_BASE_URL="http://localhost:8081"
MONO_BASE_URL="http://localhost:8090"

# ── ANSI colours ──────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
WHITE='\033[1;37m'
RESET='\033[0m'

# ── UI helpers ────────────────────────────────────────────────────────────────
banner() {
    local text="$1"
    local len=${#text}
    local bar
    bar=$(printf '═%.0s' $(seq 1 $((len + 4))))
    echo ""
    echo -e "${BOLD}${CYAN}╔${bar}╗${RESET}"
    echo -e "${BOLD}${CYAN}║  ${WHITE}${text}${CYAN}  ║${RESET}"
    echo -e "${BOLD}${CYAN}╚${bar}╝${RESET}"
    echo ""
}

section() { echo -e "\n${BOLD}${MAGENTA}▶ $*${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
info()    { echo -e "  ${CYAN}ℹ${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
err()     { echo -e "  ${RED}✗${RESET} $*"; }
step()    { echo -e "  ${DIM}→${RESET} $*"; }

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        err "Required command not found: ${BOLD}$1${RESET}"
        echo "    Install it first, then re-run."
        exit 1
    fi
}

wait_for_url() {
    local url="$1"
    local label="${2:-service}"
    local retries="${3:-30}"
    local delay="${4:-3}"
    echo -n "  Waiting for ${label} to be ready"
    for _ in $(seq 1 $retries); do
        if curl -sf "$url" -o /dev/null 2>/dev/null; then
            echo -e " ${GREEN}✓${RESET}"
            return 0
        fi
        echo -n "."
        sleep "$delay"
    done
    echo -e " ${RED}TIMEOUT${RESET}"
    return 1
}

mkdir -p "$RESULTS_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

cmd_start() {
    banner "Starting Microservices Stack"
    require_cmd docker

    section "Building & starting containers..."
    docker compose -f "$COMPOSE_MS" up -d --build

    echo ""
    section "Waiting for services..."
    wait_for_url "${MS_BASE_URL}/actuator/health" "order-service (8081)" 40 4 || \
    wait_for_url "${MS_BASE_URL}/health"          "order-service (8081)" 10 3

    wait_for_url "http://localhost:8082/health" "notification-service (8082)" 15 3

    echo ""
    ok "All services are UP!"
    echo ""
    echo -e "  ${CYAN}order-service     :${RESET} ${MS_BASE_URL}/orders"
    echo -e "  ${CYAN}notification-service:${RESET} http://localhost:8082"
    echo -e "  ${CYAN}frontend          :${RESET} http://localhost:3000"
    echo ""
    info "Open http://localhost:3000 in your browser to see the live UI"
}

cmd_stop() {
    banner "Stopping All Stacks"
    require_cmd docker

    section "Stopping microservices..."
    docker compose -f "$COMPOSE_MS" down --remove-orphans 2>/dev/null || true

    section "Stopping monolith..."
    docker compose -f "$COMPOSE_MONO" down --remove-orphans 2>/dev/null || true

    ok "All containers stopped"
}

cmd_smoke() {
    banner "Smoke Test – Microservices"
    require_cmd k6

    section "Running smoke test (5 VUs × 30 s)..."
    k6 run \
        --env BASE_URL="${MS_BASE_URL}" \
        "${K6_DIR}/smoke-test.js"
}

cmd_load() {
    banner "Load Test – Flash Sale Simulation"
    require_cmd k6
    require_cmd docker

    # ── Microservices ──
    section "Phase 1 – Load testing MICROSERVICES (port 8081)..."
    info "Ramp: 0→50→200→50 VUs over 5 minutes"
    echo ""

    k6 run \
        --env BASE_URL="${MS_BASE_URL}" \
        --out "json=${RESULTS_DIR}/load-microservices.json" \
        "${K6_DIR}/load-test.js" || true

    echo ""
    ok "Microservices results → ${RESULTS_DIR}/load-microservices.json"

    # ── Start monolith if not running ──
    section "Phase 2 – Starting MONOLITH (port 8090)..."
    docker compose -f "$COMPOSE_MONO" up -d --build
    wait_for_url "${MONO_BASE_URL}/health" "monolith (8090)" 20 3

    echo ""
    section "Phase 3 – Load testing MONOLITH (port 8090)..."
    echo ""

    k6 run \
        --env BASE_URL="${MONO_BASE_URL}" \
        --out "json=${RESULTS_DIR}/load-monolith.json" \
        "${K6_DIR}/load-test.js" || true

    echo ""
    ok "Monolith results → ${RESULTS_DIR}/load-monolith.json"

    echo ""
    section "Phase 4 – Comparison"
    cmd_compare

    # Offer PNG chart
    if command -v python3 &>/dev/null; then
        echo ""
        section "Generating comparison chart..."
        python3 "${K6_DIR}/generate-report.py" \
            --microservices "${RESULTS_DIR}/load-microservices.json" \
            --monolith      "${RESULTS_DIR}/load-monolith.json"     \
            --output        "${RESULTS_DIR}/comparison.png" 2>/dev/null || \
        warn "Chart generation skipped (install matplotlib: pip install matplotlib numpy)"
    fi
}

cmd_stress() {
    banner "Stress Test – Finding the Breaking Point"
    require_cmd k6

    warn "This test ramps up to 500 concurrent users over 14 minutes."
    warn "It is designed to saturate the system — some errors are expected."
    echo ""

    section "Running stress test against microservices..."
    k6 run \
        --env BASE_URL="${MS_BASE_URL}" \
        --out "json=${RESULTS_DIR}/stress-microservices.json" \
        "${K6_DIR}/stress-test.js" || true

    echo ""
    ok "Stress results → ${RESULTS_DIR}/stress-microservices.json"
}

cmd_compare() {
    banner "Performance Comparison Table"

    MS_FILE="${RESULTS_DIR}/load-microservices.json"
    MONO_FILE="${RESULTS_DIR}/load-monolith.json"

    # Check files exist
    if [[ ! -f "$MS_FILE" ]] || [[ ! -f "$MONO_FILE" ]]; then
        warn "Result files not found. Run ./run-demo.sh load first."
        echo ""
        echo -e "  Expected files:"
        echo -e "    ${CYAN}${MS_FILE}${RESET}"
        echo -e "    ${CYAN}${MONO_FILE}${RESET}"
        return 1
    fi

    # Use Python for rich comparison if available; else basic shell version
    if command -v python3 &>/dev/null; then
        python3 "${K6_DIR}/generate-report.py" \
            --microservices "$MS_FILE" \
            --monolith      "$MONO_FILE" \
            --ascii-only    2>/dev/null || _compare_shell "$MS_FILE" "$MONO_FILE"
    else
        _compare_shell "$MS_FILE" "$MONO_FILE"
    fi
}

# Shell-only fallback comparison (no Python needed)
_compare_shell() {
    local ms_file="$1"
    local mono_file="$2"

    # Extract p95 from k6 JSON (grep for threshold summary lines)
    local ms_p95 mono_p95

    ms_p95=$(grep -o '"p(95)":[0-9.]*' "$ms_file" 2>/dev/null | \
             head -1 | grep -o '[0-9.]*$' || echo "N/A")
    mono_p95=$(grep -o '"p(95)":[0-9.]*' "$mono_file" 2>/dev/null | \
               head -1 | grep -o '[0-9.]*$' || echo "N/A")

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         FlashOrder – Microservices vs Monolith               ║"
    echo "╠════════════════════════╦══════════════════╦══════════════════╣"
    echo "║  Metric                ║  Microservices   ║  Monolith        ║"
    echo "╠════════════════════════╬══════════════════╬══════════════════╣"
    printf "║  %-22s ║  %-16s ║  %-16s ║\n" "p95 latency"  "${ms_p95} ms"  "${mono_p95} ms"
    echo "║  (run load test for    ║  full stats...)  ║                  ║"
    echo "╚════════════════════════╩══════════════════╩══════════════════╝"
    echo ""
    info "For full stats: python3 ${K6_DIR}/generate-report.py"
}

cmd_full_demo() {
    banner "FlashOrder – Full Automated Demo"

    echo -e "  This will run the complete demo flow:"
    echo -e "  ${DIM}start → smoke → load → compare → (keypress) → stop${RESET}"
    echo ""

    # Step 1
    section "STEP 1/6 – Starting microservices"
    cmd_start

    # Step 2
    section "STEP 2/6 – Open browser"
    echo ""
    info "Open http://localhost:3000 to see the live dashboard"
    info "WebSocket notifications will fire as orders are created"
    echo ""

    # Step 3
    section "STEP 3/6 – Quick live order creation"
    if [[ -f "${SCRIPTS_DIR}/quick-test.sh" ]]; then
        bash "${SCRIPTS_DIR}/quick-test.sh"
    fi

    # Step 4
    section "STEP 4/6 – Smoke test"
    cmd_smoke

    # Step 5
    section "STEP 5/6 – Load test (microservices + monolith)"
    cmd_load

    # Step 6
    section "STEP 6/6 – Final comparison"
    cmd_compare

    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN}  Demo complete!  Results saved in ${RESULTS_DIR}/${RESET}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    echo -e "  Press ${BOLD}Enter${RESET} to stop all containers, or ${BOLD}Ctrl+C${RESET} to leave them running..."
    read -r || true

    cmd_stop
}

cmd_help() {
    echo ""
    echo -e "${BOLD}${WHITE}FlashOrder Platform – Demo Script${RESET}"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}  ./run-demo.sh [command]"
    echo ""
    echo -e "  ${BOLD}Commands:${RESET}"
    echo ""
    echo -e "  ${CYAN}start${RESET}       Build & start microservices (docker compose up)"
    echo -e "              Waits until order-service & notification-service are healthy"
    echo ""
    echo -e "  ${CYAN}smoke${RESET}       Quick sanity check – 5 VUs × 30 s"
    echo -e "              Thresholds: p95 < 500 ms, error rate < 1 %"
    echo ""
    echo -e "  ${CYAN}load${RESET}        Flash sale simulation (0→50→200→50 VUs)"
    echo -e "              Tests BOTH microservices AND monolith, then shows comparison"
    echo -e "              Saves JSON results to ${RESULTS_DIR}/"
    echo ""
    echo -e "  ${CYAN}stress${RESET}      Find breaking point – ramps to 500 VUs over 14 min"
    echo -e "              Logs the exact VU count when first error appears"
    echo ""
    echo -e "  ${CYAN}compare${RESET}     Print ASCII comparison table from saved results"
    echo -e "              Generates ${RESULTS_DIR}/comparison.png if matplotlib installed"
    echo ""
    echo -e "  ${CYAN}stop${RESET}        Tear down all Docker stacks (microservices + monolith)"
    echo ""
    echo -e "  ${CYAN}full-demo${RESET}   Runs the complete flow: start → smoke → load → compare → stop"
    echo ""
    echo -e "  ${BOLD}Environment variables:${RESET}"
    echo ""
    echo -e "  ${YELLOW}BASE_URL${RESET}    Override target URL for k6 tests"
    echo -e "              (default: ${MS_BASE_URL})"
    echo ""
    echo -e "  ${BOLD}Demo flow:${RESET}"
    echo ""
    echo -e "  ${DIM}1.${RESET} ${CYAN}./run-demo.sh start${RESET}                           # boot stack"
    echo -e "  ${DIM}2.${RESET} Open http://localhost:3000                       # live UI"
    echo -e "  ${DIM}3.${RESET} ${CYAN}./scripts/quick-test.sh${RESET}                       # live orders"
    echo -e "  ${DIM}4.${RESET} ${CYAN}./run-demo.sh smoke${RESET}                           # sanity check"
    echo -e "  ${DIM}5.${RESET} ${CYAN}docker compose -f docker-compose.monolith.yml up -d${RESET}"
    echo -e "  ${DIM}6.${RESET} ${CYAN}./run-demo.sh load${RESET}                            # head-to-head"
    echo -e "  ${DIM}7.${RESET} ${CYAN}./run-demo.sh stress${RESET}                          # break it"
    echo -e "  ${DIM}8.${RESET} ${CYAN}./run-demo.sh compare${RESET}                         # final table"
    echo -e "  ${DIM}9.${RESET} ${CYAN}./run-demo.sh stop${RESET}                            # cleanup"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

COMMAND="${1:-help}"

case "$COMMAND" in
    start)     cmd_start     ;;
    stop)      cmd_stop      ;;
    smoke)     cmd_smoke     ;;
    load)      cmd_load      ;;
    stress)    cmd_stress    ;;
    compare)   cmd_compare   ;;
    full-demo) cmd_full_demo ;;
    help|--help|-h) cmd_help ;;
    *)
        err "Unknown command: ${COMMAND}"
        echo ""
        cmd_help
        exit 1
        ;;
esac
