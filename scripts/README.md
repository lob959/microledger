# scripts/

Utility scripts for local development and testing. All scripts are written in bash and require the stack to be running via `docker compose up` before they are invoked.

---

## smoke-test.sh

An end-to-end integration test that exercises the full request path across both services.

### What it tests

1. **Health checks** — asserts both services return `{"status": "ok"}` from `/health`.
2. **Account creation** — creates a new account via `POST /accounts` and captures the generated `account_id`.
3. **Credit** — posts a credit of €100 to the new account via `POST /transactions`.
4. **Debit** — posts a debit of €30 via `POST /transactions`.
5. **Balance assertion** — reads the account via `GET /accounts/{account_id}` and asserts the balance equals €70.00.
6. **Transaction history** — reads via `GET /transactions/{account_id}` and asserts exactly 2 records exist.

Any assertion failure exits immediately with a non-zero status code and a red `✗` indicator. All six checks passing prints a green summary.

### Running

```bash
# From the repo root (recommended)
make smoke-test

# Or directly
bash scripts/smoke-test.sh
```

### Prerequisites

- The full stack must be running (`make run` or `docker compose up`)
- `curl` must be available on `PATH`
- `python3` must be available on `PATH` (used for inline JSON parsing)

### How it works

The script uses `curl -sf` (silent + fail-on-error) for all HTTP calls. Responses are piped into a one-liner `python3 -c` expression that loads the JSON and extracts the relevant field. This avoids a `jq` dependency while keeping the parsing reliable.

The balance assertion uses Python to compare floating-point values (`float('$BALANCE') == 70.0`) rather than a string comparison, which avoids false failures from formatting differences (e.g. `70` vs `70.0`).

### Extending

To add a new test step, follow the existing pattern:

```bash
header "N. Description of step"

RESULT=$(curl -sf -X METHOD "$SERVICE/path" \
  -H "Content-Type: application/json" \
  -d '{"key": "value"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['field'])")

[ "$RESULT" = "expected" ] && pass "Assertion label" || fail "Failure message"
```
