# Account Service

The Account Service owns all account and balance data. It is one of two microservices that make up LedgerLite — the other is the [Transaction Service](../transaction-service).

The service exposes a public API for creating and reading accounts, and an **internal-only** endpoint for updating balances. The balance endpoint is not reachable via the public ALB listener — it is called exclusively by the Transaction Service over the internal VPC network.

---

## Endpoints

| Method | Path | Status | Description |
| --- | --- | --- | --- |
| `GET` | `/health` | `200` | Health check — returns service name and deployed version |
| `POST` | `/accounts` | `201` | Create a new account with a zero starting balance |
| `GET` | `/accounts/{account_id}` | `200` | Retrieve account details and current balance |
| `PUT` | `/accounts/{account_id}/balance` | `200` | **Internal only** — adjust balance; called by Transaction Service |

### POST /accounts

Creates a new account with a zero starting balance.

**Request body:**

```json
{
  "owner": "Lloyd",
  "currency": "EUR"
}
```

| Field | Type | Constraints |
| --- | --- | --- |
| `owner` | string | Required; 1–100 characters |
| `currency` | string | Optional; ISO 4217 code (3 uppercase letters). Defaults to `"EUR"` |

**Response (`201 Created`):**

```json
{
  "account_id": "acc_4f3a1b2c",
  "owner": "Lloyd",
  "currency": "EUR",
  "balance": 0.0,
  "created_at": "2026-06-04T10:00:00+00:00",
  "updated_at": "2026-06-04T10:00:00+00:00"
}
```

The `account_id` is auto-generated as `acc_` followed by 8 hex characters from a UUID.

### GET /accounts/{account_id}

Returns account details including the current balance. Returns `404` if the account does not exist.

### PUT /accounts/{account_id}/balance

**This endpoint is internal only.** It is not exposed via the public ALB — only the Transaction Service can reach it from within the VPC.

Adjusts the account balance by the given amount. A positive `adjustment` is a credit; negative is a debit.

**Request body:**

```json
{
  "adjustment": 100.0
}
```

The update is **atomic** — it uses a DynamoDB `UpdateExpression` (`SET balance = balance + :adj`) with a `ConditionExpression` that rejects the write if the account does not exist. This prevents a silent partial-record write and means the Transaction Service gets a clean `404` if it references a non-existent account.

**Error responses:**

| Code | Cause |
| --- | --- |
| `404` | Account does not exist (`ConditionalCheckFailedException`) |
| `500` | DynamoDB write failed |

---

## Configuration

All configuration is supplied via environment variables.

| Variable | Default | Description |
| --- | --- | --- |
| `DYNAMODB_TABLE` | `ledgerlite-accounts` | DynamoDB table name for accounts |
| `DYNAMODB_ENDPOINT_URL` | *(unset)* | Set in local dev to point at DynamoDB Local. Absent in AWS — boto3 uses the default region endpoint |
| `AWS_REGION` | `eu-west-1` | AWS region for the DynamoDB client |
| `APP_VERSION` | `local` | Deployed version; set to the Git SHA by CI. Surfaced at `/health` |
| `SERVICE_NAME` | `account-service` | Included in every structured log line |
| `LOG_LEVEL` | `INFO` | Python logging level |

Copy `.env.example` to `.env` to configure the service for local development outside of Docker Compose.

---

## Credentials

**Local development:** `DYNAMODB_ENDPOINT_URL` is set to `http://dynamodb-local:8000`. boto3 requires `aws_access_key_id` and `aws_secret_access_key` to be present even though DynamoDB Local ignores them — they are hardcoded to `"dummy"` in `app/database.py`.

**AWS (production):** No credentials are injected. boto3 automatically discovers the ECS task role via the instance metadata service (IMDS). The task role has a least-privilege IAM policy granting only the DynamoDB actions this service needs.

---

## Running Standalone

The easiest way to run the full stack is from the repo root with `docker compose up --build`. To run just this service in a container:

```bash
docker build -t account-service .

docker run -p 8002:8000 \
  -e DYNAMODB_ENDPOINT_URL=http://host.docker.internal:8000 \
  -e AWS_REGION=eu-west-1 \
  account-service
```

This requires DynamoDB Local to already be running and accessible.

---

## File Layout

```
account-service/
├── app/
│   ├── __init__.py      # Marks app/ as a Python package; required for relative imports
│   ├── main.py          # FastAPI application — models, endpoints, atomic balance update
│   ├── database.py      # boto3 DynamoDB resource factory; handles local vs AWS credential switching
│   └── logger.py        # Structured JSON log formatter for CloudWatch Log Insights
├── Dockerfile           # Multi-stage build; non-root runtime user
├── requirements.txt     # Python dependencies
└── .env.example         # Template for local environment variables
```

See [`app/README.md`](app/README.md) for a detailed breakdown of each source file.
