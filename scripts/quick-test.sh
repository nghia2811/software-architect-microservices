#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# FlashOrder – Quick API Test
# Creates 5 test orders against the running microservices stack, then fetches
# and displays them.  Great for live demos — shows WebSocket notifications
# firing in the browser at http://localhost:3000 as each order is created.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8081}"
DELAY="${DELAY:-1}"     # seconds between orders (set to 0 for speed demo)

# ── ANSI colours ─────────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
header() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }
ok()     { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET} $*"; }
err()    { echo -e "  ${RED}✗${RESET} $*"; }

require_cmd() {
    command -v "$1" &>/dev/null || { err "Required command not found: $1"; exit 1; }
}

require_cmd curl
require_cmd jq

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║        FlashOrder – Live Demo Quick Test         ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Creates 5 orders & shows them (watch :3000!)   ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${CYAN}Target:${RESET} ${BASE_URL}"
echo -e "  ${CYAN}Delay :${RESET} ${DELAY}s between orders"
echo ""

# ── Health check ──────────────────────────────────────────────────────────────
header "Step 1 – Health Check"
if curl -sf "${BASE_URL}/actuator/health" -o /dev/null 2>/dev/null || \
   curl -sf "${BASE_URL}/health"          -o /dev/null 2>/dev/null; then
    ok "Service is UP at ${BASE_URL}"
else
    err "Service not reachable at ${BASE_URL}"
    echo ""
    echo "  Is the stack running? Try:  ./run-demo.sh start"
    exit 1
fi

# ── Test data ─────────────────────────────────────────────────────────────────
declare -a CUSTOMERS=(
    "Nguyễn Văn An"
    "Trần Thị Bình"
    "Lê Minh Cường"
    "Phạm Thị Dung"
    "Hoàng Văn Em"
)
declare -a PRODUCTS=(
    "iPhone 15 Pro Max"
    "Samsung Galaxy S24 Ultra"
    "MacBook Air M3"
    "AirPods Pro 2nd Gen"
    "Apple Watch Series 9"
)
declare -a AMOUNTS=(
    34990000
    31990000
    28990000
    6490000
    11990000
)

# ── Create 5 orders ───────────────────────────────────────────────────────────
header "Step 2 – Creating 5 Test Orders  (watch http://localhost:3000 for notifications!)"
echo ""

ORDER_IDS=()
for i in 0 1 2 3 4; do
    CUSTOMER="${CUSTOMERS[$i]}"
    PRODUCT="${PRODUCTS[$i]}"
    AMOUNT="${AMOUNTS[$i]}"

    PAYLOAD=$(jq -n \
        --arg c "$CUSTOMER" \
        --arg p "$PRODUCT" \
        --argjson a "$AMOUNT" \
        '{customerName: $c, productName: $p, amount: $a}')

    FORMATTED_AMOUNT=$(python3 -c "print(f'{$AMOUNT:,}')" 2>/dev/null || echo "$AMOUNT")
    echo -e "  ${YELLOW}→${RESET} Order $((i+1))/5: ${CUSTOMER} • ${PRODUCT} • ${FORMATTED_AMOUNT} VND"

    RESPONSE=$(curl -sf \
        -X POST "${BASE_URL}/orders" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>&1) || {
        err "Failed to create order $((i+1))"
        echo "     Response: ${RESPONSE}"
        continue
    }

    ORDER_ID=$(echo "$RESPONSE" | jq -r '.id // .orderId // empty')
    if [[ -n "$ORDER_ID" ]]; then
        ok "Created → id: ${ORDER_ID}"
        ORDER_IDS+=("$ORDER_ID")
    else
        warn "Order created but couldn't parse id. Response: ${RESPONSE}"
    fi

    if [[ $i -lt 4 ]]; then
        sleep "${DELAY}"
    fi
done

echo ""
ok "Created ${#ORDER_IDS[@]} orders"

# ── Fetch and display all orders ──────────────────────────────────────────────
header "Step 3 – Fetching All Orders"
echo ""

ALL_ORDERS=$(curl -sf "${BASE_URL}/orders" 2>&1) || {
    err "GET /orders failed"
    exit 1
}

COUNT=$(echo "$ALL_ORDERS" | jq 'length')
echo -e "  ${GREEN}Total orders in DB:${RESET} ${COUNT}"
echo ""

# Pretty-print last 5
echo "$ALL_ORDERS" | jq -r '
  .[:5][] |
  "  ┌─ \(.customerName // .customer_name)\n" +
  "  │  Product : \(.productName // .product_name)\n" +
  "  │  Amount  : \(.amount | tostring) VND\n" +
  "  │  Status  : \(.status // "PENDING")\n" +
  "  └─ ID: \(.id // .orderId)"
' 2>/dev/null || echo "$ALL_ORDERS" | jq '.[:5]'

# ── Footer ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Demo complete! Check the browser for WebSocket events.${RESET}"
echo -e "${GREEN}  Run load test: ./run-demo.sh load${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
