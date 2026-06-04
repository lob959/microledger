# transaction-service/app/

All application source code for the Transaction Service. Three modules with distinct responsibilities: application logic (`main.py`), data access (`database.py`), and observability (`logger.py`).

---

## main.py

The FastAPI application. Defines the Pydantic models, registers the endpoints, and implements the two-step transaction flow.

### Pydantic models

**`TransactionRequest`** — validates the `POST /transactions` request body:

| Field | Type | Validation |
| --- | --- | --- |
| `account_id` | `str` | Required |
| `amount` | `float` | Required; `Field(gt=0)` rejects zero and negative values at the framework layer before the handler runs |
| `type` | `Literal["credit", "debit"]` | Only these two strings are accepted; anything else returns `422` |
| `description` | `Optional[str]` | Defaults to `""` |

**`TransactionResponse`** — shapes the `201` response body. Having a dedicated response model means FastAPI validates outbound data too, and the auto-generated docs show the exact response shape.

### DynamoDB item schema

Transactions are stored with this structure:

```python
{
    "account_id":     str,      # partition key — groups all transactions for an account
    "transaction_id": str,      # sort key — UUID generated at write time
    "amount":         Decimal,  # stored as Decimal; DynamoDB rejects Python float directly
    "type":           str,      # "credit" or "debit"
    "description":    str,
    "created_at":     str,      # UTC ISO 8601 string
}
```

`amount` is converted via `Decimal(str(transaction.amount))`. The intermediate string step is intentional — going float → Decimal directly can introduce floating-point precision artefacts before the value is stored.

When reading back from DynamoDB, `Decimal` values are converted to `float` before returning so FastAPI can serialise them to JSON (the standard `json` module does not handle `Decimal`).

### Endpoint: GET /health

Returns the service name and the value of `APP_VERSION`. In AWS, `APP_VERSION` is set to the Git SHA by the CI pipeline — confirming exactly which build is deployed without needing to open the console.

### Endpoint: POST /transactions

Two-step flow:

**Step 1 — DynamoDB write.** The transaction item is written with `table.put_item()`. If this raises any exception the handler returns `500` and stops. The record is not visible to callers until this succeeds.

**Step 2 — Account Service call.** An `httpx.AsyncClient` makes a `PUT` to `/accounts/{account_id}/balance` with a signed `adjustment` value (positive for credit, negative for debit). A 5-second timeout is set. If the Account Service returns a non-2xx status or is unreachable, the handler returns `502`.

**Important:** step 1 is committed before step 2 is attempted. A failure in step 2 means the transaction record exists in DynamoDB but the account balance has not been updated. Both logger calls at this failure point are `.error()` level and include the `transaction_id` so the inconsistency can be found and reconciled.

### Endpoint: GET /transactions/{account_id}

Queries DynamoDB with `KeyConditionExpression=Key("account_id").eq(account_id)`. Because `account_id` is the partition key, this is a direct key lookup — not a table scan — and scales independently of the total number of transactions in the table.

Results are returned in DynamoDB's natural sort order (by `transaction_id`). For large accounts, pagination via `ExclusiveStartKey` would need to be added.

---

## database.py

A small factory module. Its single responsibility is returning a boto3 DynamoDB `Table` resource for a given table name, with credentials appropriate for the current environment.

### Credential switching

```python
endpoint_url = os.getenv("DYNAMODB_ENDPOINT_URL")

if endpoint_url:
    # Local development — DynamoDB Local path
    return boto3.resource("dynamodb", endpoint_url=endpoint_url, ..., aws_access_key_id="dummy", ...)
else:
    # AWS — ECS task role path
    return boto3.resource("dynamodb", region_name=...)
```

When `DYNAMODB_ENDPOINT_URL` is set (local dev), boto3 points at DynamoDB Local. boto3 requires `aws_access_key_id` and `aws_secret_access_key` to be present in this call even though DynamoDB Local ignores them — `"dummy"` satisfies the requirement.

When `DYNAMODB_ENDPOINT_URL` is absent (AWS), no credentials are passed. boto3 walks its default credential chain and picks up the ECS task role automatically via the instance metadata service (IMDS).

`get_table(table_name)` calls `get_dynamodb_resource().Table(table_name)`. Keeping the factory call inside `get_table` means a new resource object is created per call rather than being cached globally — acceptable overhead for a low-concurrency service, and avoids stale connection state across requests.

---

## logger.py

A `logging.Formatter` subclass that emits each log record as a single-line JSON object.

### Output format

Every log line contains these fields:

```json
{
  "timestamp": "2026-06-04T10:00:00+00:00",
  "level": "INFO",
  "service": "transaction-service",
  "logger": "app.main",
  "message": "Transaction written to DynamoDB",
  "transaction_id": "d4e5f6a7-...",
  "account_id": "acc_4f3a1b2c",
  "amount": 100.0,
  "type": "credit"
}
```

The core fields come from the `LogRecord`. Fields passed via `extra={}` in the logging call are merged in after — this is how callers attach context-specific data (`transaction_id`, `account_id`, etc.).

### RESERVED_ATTRS

`StructuredJSONFormatter` defines a set of standard `LogRecord` attribute names to exclude from the `extra` merge. Without this, internal Python logging fields (`lineno`, `pathname`, `thread`, etc.) would bleed into every log line and pollute the output.

### get_logger

```python
def get_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    if not logger.handlers:
        ...
        logger.addHandler(handler)
    return logger
```

The `if not logger.handlers` guard prevents duplicate handlers being added if `get_logger` is called more than once for the same name. Python's logging module is process-global — without this guard, each import would add another handler and every log line would be printed multiple times.

### Why JSON?

CloudWatch Log Insights can filter and aggregate structured JSON natively using the `filter` and `stats` commands. With JSON logs, querying "all transactions over €500" or "all errors for account X" is a simple Log Insights expression — no regex parsing required.
