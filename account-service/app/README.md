# account-service/app/

All application source code for the Account Service. Three modules with distinct responsibilities: application logic (`main.py`), data access (`database.py`), and observability (`logger.py`).

---

## main.py

The FastAPI application. Defines the Pydantic models, registers the endpoints, and implements the atomic balance update pattern.

### Pydantic models

**`CreateAccountRequest`** — validates the `POST /accounts` request body:

| Field | Type | Validation |
| --- | --- | --- |
| `owner` | `str` | Required; `min_length=1`, `max_length=100` |
| `currency` | `str` | Optional; `pattern=r"^[A-Z]{3}$"` enforces ISO 4217 format (3 uppercase letters). Defaults to `"EUR"` |

**`BalanceAdjustmentRequest`** — validates the internal `PUT .../balance` request body:

| Field | Type | Validation |
| --- | --- | --- |
| `adjustment` | `float` | Required; `Field(ne=0)` rejects zero — a zero adjustment would be a no-op and most likely a caller bug |

### DynamoDB item schema

Accounts are stored with this structure:

```python
{
    "account_id": str,      # partition key — format "acc_" + 8 hex chars
    "owner":      str,
    "currency":   str,      # ISO 4217, e.g. "EUR"
    "balance":    Decimal,  # stored as Decimal; never float — precision matters for money
    "created_at": str,      # UTC ISO 8601
    "updated_at": str,      # UTC ISO 8601; set on both create and balance update
}
```

### Endpoint: GET /health

Returns service name and `APP_VERSION`. In AWS, `APP_VERSION` is set to the Git SHA by the CI pipeline.

### Endpoint: POST /accounts

Generates an `account_id` (`acc_` + first 8 hex characters of a UUID) and writes a new item to DynamoDB with `balance` set to `Decimal("0")`. The `"0"` string is used rather than `0` or `Decimal(0)` to be explicit about the initial value and avoid any integer-vs-decimal ambiguity in DynamoDB.

### Endpoint: GET /accounts/{account_id}

Retrieves the account using `table.get_item(Key={"account_id": account_id})`. Returns `404` if the item is not present. `Decimal` balance is converted to `float` before returning so FastAPI can serialise it to JSON.

### Endpoint: PUT /accounts/{account_id}/balance

**This endpoint is internal only** — it is not exposed on the public ALB listener and is only reachable from within the VPC.

The balance update is **atomic** and uses two DynamoDB features together:

**1. Atomic increment:**
```python
UpdateExpression="SET balance = balance + :adj, updated_at = :ts"
```
DynamoDB applies this as a single atomic operation on the server side. There is no read-modify-write cycle in the application code — this means concurrent updates from multiple Transaction Service instances cannot race and corrupt the balance.

**2. Existence guard:**
```python
ConditionExpression="attribute_exists(account_id)"
```
The update is rejected with `ConditionalCheckFailedException` if no item with this `account_id` exists. Without this guard, DynamoDB would silently create a partial item with only the updated fields — a corrupted record. The condition converts a silent data problem into an explicit `404`.

The exception is caught and inspected by checking `exc.response["Error"]["Code"]`. Only `ConditionalCheckFailedException` returns `404`; all other exceptions return `500`.

---

## database.py

Identical in structure to the Transaction Service's `database.py`. See the [transaction-service app README](../../transaction-service/app/README.md#databasepy) for a full explanation of the credential switching logic.

In summary: when `DYNAMODB_ENDPOINT_URL` is set, boto3 points at DynamoDB Local with `"dummy"` credentials. When it is absent, boto3 picks up the ECS task role automatically. `get_table(table_name)` is the single entry point used by all handlers.

---

## logger.py

Identical in structure to the Transaction Service's `logger.py`. See the [transaction-service app README](../../transaction-service/app/README.md#loggerpy) for a full explanation of the JSON formatter, `RESERVED_ATTRS`, and the `get_logger` duplicate-handler guard.

The only difference is that `SERVICE_NAME` defaults to `"account-service"` in this container's environment, so every log line is labelled accordingly.
