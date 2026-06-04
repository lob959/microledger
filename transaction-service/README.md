# Transaction Service

The Transaction Service is responsible for creating and retrieving financial transactions. It is one of two microservices that make up LedgerLite — the other is the [Account Service](../account-service).

When a transaction is created, the service performs two sequential operations:

1. Persists the transaction record to its own DynamoDB table (`ledgerlite-transactions`).
2. Calls the Account Service over the internal network to adjust the account balance.

The service does not own or store account data. Balance state is fully delegated to the Account Service.

---

## Endpoints

| Method | Path | Status | Description |
| --- | --- | --- | --- |
| `GET` | `/health` | `200` | Health check — returns service name and deployed version |
| `POST` | `/transactions` | `201` | Create a transaction and trigger a balance update |
| `GET` | `/transactions/{account_id}` | `200` | List all transactions for an account |

### POST /transactions

Creates a new transaction. The request body is validated by Pydantic before the handler runs — invalid payloads are rejected with `422 Unprocessable Entity`.

**Request body:**

```json
{
  "account_id": "acc_4f3a1b2c",
  "amount": 100.0,
  "type": "credit",
  "description": "Salary"
}
```

| Field | Type | Constraints |
| --- | --- | --- |
| `account_id` | string | Required |
| `amount` | number | Required; must be greater than 0 |
| `type` | string | Required; `"credit"` or `"debit"` only |
| `description` | string | Optional; defaults to `""` |

**Response (`201 Created`):**

```json
{
  "transaction_id": "d4e5f6a7-...",
  "account_id": "acc_4f3a1b2c",
  "amount": 100.0,
  "type": "credit",
  "description": "Salary",
  "created_at": "2026-06-04T10:00:00+00:00"
}
```

**Error responses:**

| Code | Cause |
| --- | --- |
| `422` | Request body failed Pydantic validation |
| `500` | DynamoDB write failed |
| `502` | Account Service rejected the balance update or was unreachable |

### GET /transactions/{account_id}

Returns all transactions for an account, ordered by `transaction_id` (insert order). The `account_id` is the DynamoDB partition key, so this is an efficient key lookup — not a table scan.

**Response (`200 OK`):**

```json
{
  "account_id": "acc_4f3a1b2c",
  "count": 2,
  "transactions": [
    {
      "account_id": "acc_4f3a1b2c",
      "transaction_id": "d4e5f6a7-...",
      "amount": 100.0,
      "type": "credit",
      "description": "Salary",
      "created_at": "2026-06-04T10:00:00+00:00"
    }
  ]
}
```

---

## Transaction Flow

```
Client
  │
  ▼
POST /transactions
  │
  ├─ 1. Validate request (Pydantic)
  │
  ├─ 2. Generate transaction_id (UUID) + created_at (UTC ISO 8601)
  │
  ├─ 3. Write transaction record to DynamoDB
  │       └─ On failure → 500, stop here
  │
  ├─ 4. Call PUT /accounts/{account_id}/balance on Account Service
  │       ├─ credits → positive adjustment
  │       ├─ debits  → negative adjustment
  │       └─ On failure → 502 (transaction record already written)
  │
  └─ 5. Return 201 with transaction details
```

**Consistency note:** The transaction record is persisted before the balance update is attempted. If step 4 fails, the record exists but the balance has not been updated — the inconsistency is logged. In a production system, a DynamoDB Stream or SQS dead-letter queue would reconcile this automatically.

---

## Configuration

All configuration is supplied via environment variables. The `docker-compose.yml` sets these for local development; in AWS they are injected by the ECS task definition via SSM Parameter Store.

| Variable | Default | Description |
| --- | --- | --- |
| `DYNAMODB_TABLE` | `ledgerlite-transactions` | DynamoDB table name for transactions |
| `ACCOUNT_SERVICE_URL` | `http://localhost:8002` | Base URL of the Account Service |
| `DYNAMODB_ENDPOINT_URL` | *(unset)* | Set in local dev to point at DynamoDB Local. Absent in AWS — boto3 uses the default region endpoint |
| `AWS_REGION` | `eu-west-1` | AWS region for the DynamoDB client |
| `APP_VERSION` | `local` | Deployed version; set to the Git SHA by CI. Surfaced at `/health` |
| `SERVICE_NAME` | `transaction-service` | Included in every structured log line |
| `LOG_LEVEL` | `INFO` | Python logging level |

Copy `.env.example` to `.env` to configure the service for local development outside of Docker Compose.

---

## Credentials

**Local development:** `DYNAMODB_ENDPOINT_URL` is set to `http://dynamodb-local:8000`. boto3 requires `aws_access_key_id` and `aws_secret_access_key` to be present even though DynamoDB Local ignores them — they are hardcoded to `"dummy"` in `app/database.py`.

**AWS (production):** No credentials are injected. boto3 automatically discovers the ECS task role via the instance metadata service (IMDS) and uses it to sign requests. See `app/database.py` for the credential switching logic.

---

## Running Standalone

The easiest way to run the full stack is from the repo root with `docker compose up --build`. To run just this service in a container:

```bash
docker build -t transaction-service .

docker run -p 8001:8000 \
  -e DYNAMODB_ENDPOINT_URL=http://host.docker.internal:8000 \
  -e ACCOUNT_SERVICE_URL=http://host.docker.internal:8002 \
  -e AWS_REGION=eu-west-1 \
  transaction-service
```

This requires DynamoDB Local and the Account Service to already be running and accessible.

---

## File Layout

```
transaction-service/
├── app/
│   ├── __init__.py      # Marks app/ as a Python package; required for relative imports
│   ├── main.py          # FastAPI application — models, endpoints, transaction flow
│   ├── database.py      # boto3 DynamoDB resource factory; handles local vs AWS credential switching
│   └── logger.py        # Structured JSON log formatter for CloudWatch Log Insights
├── Dockerfile           # Multi-stage build; non-root runtime user
├── requirements.txt     # Python dependencies
└── .env.example         # Template for local environment variables
```

See [`app/README.md`](app/README.md) for a detailed breakdown of each source file.
