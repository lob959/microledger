#!/usr/bin/env bash
# scripts/smoke-test.sh
#
# End-to-end integration test for the LedgerLite local stack.
#
# What it covers:
#   1. Health checks on both services
#   2. Account creation
#   3. Posting a credit transaction (€100)
#   4. Posting a debit transaction (€30)
#   5. Asserting the resulting balance is €70.00
#   6. Asserting exactly 2 transactions exist for the account
#
# Prerequisites:
#   - The full stack must be running: make run (or docker compose up)
#   - curl and python3 must be on PATH
#
# Exit behaviour:
#   - 'set -e' causes the script to exit immediately on any non-zero return code.
#   - 'set -u' treats unset variables as errors, catching typos in variable names.
#   - 'set -o pipefail' ensures a failing command in a pipeline (e.g. curl | python3)
#     propagates the failure — without this, only the last command's exit code matters.

set -euo pipefail

# Base URLs for both services. These match the port mappings in docker-compose.yml.
# Override by setting ACCOUNT_SVC or TRANSACTION_SVC in the environment before running.
ACCOUNT_SVC="${ACCOUNT_SVC:-http://localhost:8002}"
TRANSACTION_SVC="${TRANSACTION_SVC:-http://localhost:8001}"

# ── Terminal formatting helpers ───────────────────────────────────────────────
# ANSI escape codes for coloured output. These make pass/fail easy to scan.
# The RESET code clears all formatting so subsequent text is unaffected.
BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# pass / fail / header are one-line helpers used throughout the test steps.
# 'fail' calls 'exit 1' — any failed assertion terminates the whole script immediately.
pass()   { echo -e "${GREEN}✓${RESET} $1"; }
fail()   { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

header "=== LedgerLite Smoke Test ==="

# ── 1. Health checks ──────────────────────────────────────────────────────────
# Confirm both services are up and returning a healthy response before running
# any data-mutating steps. This avoids confusing errors later if a service is
# still starting up.
#
# curl flags:
#   -s  silent mode — suppresses the progress meter
#   -f  fail-on-error — exits non-zero on HTTP 4xx/5xx (without this, curl
#       returns 0 even for 404 responses)
#
# The response is piped into a python3 one-liner that parses the JSON and prints
# the value of the 'status' field. This avoids a jq dependency while keeping
# the parsing reliable.
header "1. Health checks"

TX_HEALTH=$(curl -sf "$TRANSACTION_SVC/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
[ "$TX_HEALTH" = "ok" ] && pass "Transaction Service healthy" || fail "Transaction Service unhealthy"

ACC_HEALTH=$(curl -sf "$ACCOUNT_SVC/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
[ "$ACC_HEALTH" = "ok" ] && pass "Account Service healthy" || fail "Account Service unhealthy"

# ── 2. Create account ─────────────────────────────────────────────────────────
# Create a fresh account for this test run. Using a new account each time means
# the test is idempotent — re-running it will not interfere with previous runs
# or leave unexpected state. The generated account_id is captured and reused in
# all subsequent steps.
header "2. Create account"

# POST the account creation request and capture the full JSON response.
# The -X POST flag sets the HTTP method. -H sets the Content-Type header so the
# server knows to parse the body as JSON.
ACCOUNT_JSON=$(curl -sf -X POST "$ACCOUNT_SVC/accounts" \
  -H "Content-Type: application/json" \
  -d '{"owner": "Lloyd", "currency": "EUR"}')

# Extract account_id from the response JSON. All subsequent curl calls use this
# value to associate transactions with the correct account.
ACCOUNT_ID=$(echo "$ACCOUNT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['account_id'])")
pass "Account created: $ACCOUNT_ID"

# ── 3. Credit €100 ────────────────────────────────────────────────────────────
# Post a credit transaction. A credit increases the balance.
# The Transaction Service writes the record to DynamoDB and then calls the
# Account Service internally to apply the +100 adjustment.
# '> /dev/null' discards the response body — we only care that it succeeded
# (curl -f would have exited non-zero on any HTTP error).
header "3. Post credit of €100"

curl -sf -X POST "$TRANSACTION_SVC/transactions" \
  -H "Content-Type: application/json" \
  -d "{\"account_id\": \"$ACCOUNT_ID\", \"amount\": 100, \"type\": \"credit\", \"description\": \"Salary\"}" \
  > /dev/null

pass "Credit of €100 posted"

# ── 4. Debit €30 ──────────────────────────────────────────────────────────────
# Post a debit transaction. A debit decreases the balance.
# After this step the expected balance is €100 - €30 = €70.
header "4. Post debit of €30"

curl -sf -X POST "$TRANSACTION_SVC/transactions" \
  -H "Content-Type: application/json" \
  -d "{\"account_id\": \"$ACCOUNT_ID\", \"amount\": 30, \"type\": \"debit\", \"description\": \"Groceries\"}" \
  > /dev/null

pass "Debit of €30 posted"

# ── 5. Verify balance ─────────────────────────────────────────────────────────
# Fetch the account from the Account Service and assert the balance is exactly
# €70.00. We use Python floating-point comparison rather than a string match to
# avoid false failures from formatting differences (e.g. "70" vs "70.0").
#
# python3 -c "sys.exit(0 if ... else 1)" exits with 0 (success) when the
# condition is true and 1 (failure) otherwise — this integrates cleanly with
# the shell's [ ... ] and the set -e behaviour.
header "5. Verify balance (expected: €70.00)"

ACCOUNT_DATA=$(curl -sf "$ACCOUNT_SVC/accounts/$ACCOUNT_ID")
BALANCE=$(echo "$ACCOUNT_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['balance'])")

if python3 -c "import sys; sys.exit(0 if float('$BALANCE') == 70.0 else 1)"; then
  pass "Balance is €$BALANCE ✓"
else
  fail "Expected €70.00 but got €$BALANCE"
fi

# ── 6. Verify transaction history ─────────────────────────────────────────────
# Fetch all transactions for the account and assert the count is exactly 2 —
# one credit and one debit. This confirms both records were persisted and that
# the GET /transactions endpoint returns the correct result set.
header "6. Verify transaction history (expected: 2 records)"

TX_COUNT=$(curl -sf "$TRANSACTION_SVC/transactions/$ACCOUNT_ID" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")

[ "$TX_COUNT" = "2" ] && pass "Transaction count: $TX_COUNT" || fail "Expected 2 transactions, got $TX_COUNT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}All checks passed.${RESET}"
echo ""
echo "  Account ID : $ACCOUNT_ID"
echo "  Balance    : €$BALANCE"
echo ""
echo "  Explore the APIs:"
echo "    Transaction Service → $TRANSACTION_SVC/docs"
echo "    Account Service     → $ACCOUNT_SVC/docs"
