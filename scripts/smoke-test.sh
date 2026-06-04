#!/usr/bin/env bash
# scripts/smoke-test.sh
# End-to-end test: create account → credit → debit → verify balance
# Requires: curl, python3

set -euo pipefail

ACCOUNT_SVC="http://localhost:8002"
TRANSACTION_SVC="http://localhost:8001"

BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

pass() { echo -e "${GREEN}✓${RESET} $1"; }
fail() { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

header "=== LedgerLite Smoke Test ==="

# ── 1. Health checks ───────────────────────────────────────────────────────
header "1. Health checks"

TX_HEALTH=$(curl -sf "$TRANSACTION_SVC/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
[ "$TX_HEALTH" = "ok" ] && pass "Transaction Service healthy" || fail "Transaction Service unhealthy"

ACC_HEALTH=$(curl -sf "$ACCOUNT_SVC/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
[ "$ACC_HEALTH" = "ok" ] && pass "Account Service healthy" || fail "Account Service unhealthy"

# ── 2. Create account ──────────────────────────────────────────────────────
header "2. Create account"

ACCOUNT_JSON=$(curl -sf -X POST "$ACCOUNT_SVC/accounts" \
  -H "Content-Type: application/json" \
  -d '{"owner": "Lloyd", "currency": "EUR"}')

ACCOUNT_ID=$(echo "$ACCOUNT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['account_id'])")
pass "Account created: $ACCOUNT_ID"

# ── 3. Credit €100 ────────────────────────────────────────────────────────
header "3. Post credit of €100"

curl -sf -X POST "$TRANSACTION_SVC/transactions" \
  -H "Content-Type: application/json" \
  -d "{\"account_id\": \"$ACCOUNT_ID\", \"amount\": 100, \"type\": \"credit\", \"description\": \"Salary\"}" \
  > /dev/null

pass "Credit of €100 posted"

# ── 4. Debit €30 ──────────────────────────────────────────────────────────
header "4. Post debit of €30"

curl -sf -X POST "$TRANSACTION_SVC/transactions" \
  -H "Content-Type: application/json" \
  -d "{\"account_id\": \"$ACCOUNT_ID\", \"amount\": 30, \"type\": \"debit\", \"description\": \"Groceries\"}" \
  > /dev/null

pass "Debit of €30 posted"

# ── 5. Verify balance ─────────────────────────────────────────────────────
header "5. Verify balance (expected: €70.00)"

ACCOUNT_DATA=$(curl -sf "$ACCOUNT_SVC/accounts/$ACCOUNT_ID")
BALANCE=$(echo "$ACCOUNT_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['balance'])")

if python3 -c "import sys; sys.exit(0 if float('$BALANCE') == 70.0 else 1)"; then
  pass "Balance is €$BALANCE ✓"
else
  fail "Expected €70.00 but got €$BALANCE"
fi

# ── 6. Verify transaction history ─────────────────────────────────────────
header "6. Verify transaction history (expected: 2 records)"

TX_COUNT=$(curl -sf "$TRANSACTION_SVC/transactions/$ACCOUNT_ID" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")

[ "$TX_COUNT" = "2" ] && pass "Transaction count: $TX_COUNT" || fail "Expected 2 transactions, got $TX_COUNT"

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}All checks passed.${RESET}"
echo ""
echo "  Account ID : $ACCOUNT_ID"
echo "  Balance    : €$BALANCE"
echo ""
echo "  Explore the APIs:"
echo "    Transaction Service → $TRANSACTION_SVC/docs"
echo "    Account Service     → $ACCOUNT_SVC/docs"