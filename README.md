# LedgerLite

A containerised microledger built with Python, deployed on **AWS Fargate**, and provisioned end-to-end with Terraform.

Two FastAPI services -- **Account Service** and **Transaction Service** -- communicate over an internal network path, backed by DynamoDB. Local development runs the full stack via Docker Compose in a single command. Production runs on AWS Fargate with infrastructure provisioned by Terraform.

---

## Architecture

```
                     +---------------------------------------------+
                     |                  AWS VPC                    |
                     |                                             |
  Internet -> ALB -->|--> transaction-service --> account-service  |
                     |            |                     |          |
                     |            v                     v          |
                     |     DynamoDB table         DynamoDB table   |
                     |    (transactions)            (accounts)     |
                     +---------------------------------------------+
```

Both services run as **ECS Fargate** tasks. The ALB forwards public traffic to both services. The balance endpoint on the Account Service (`PUT /accounts/{id}/balance`) is **not** exposed via the public ALB listener -- it is only reachable from within the VPC, called internally by the Transaction Service.

---

## FastAPI

Both services are built on [FastAPI](https://fastapi.tiangolo.com/). Key features used in this project:

- **Pydantic models** -- all request and response bodies are validated at the framework layer. Invalid payloads are rejected with a structured `422` before reaching any handler logic.
- **Async handlers** -- the Transaction Service uses `async def` and `httpx.AsyncClient` for the inter-service balance call, keeping the event loop free during the outbound HTTP request.
- **Auto-generated docs** -- FastAPI generates interactive API documentation from the Pydantic models and endpoint docstrings with no extra configuration.

Once the stack is running, open the docs in a browser:

| Service | Swagger UI | ReDoc |
| --- | --- | --- |
| Transaction Service | http://localhost:8001/docs | http://localhost:8001/redoc |
| Account Service | http://localhost:8002/docs | http://localhost:8002/redoc |

### Endpoints

**Account Service** (`localhost:8002`)

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/health` | Health check -- returns service name and version |
| `POST` | `/accounts` | Create a new account with a zero starting balance |
| `GET` | `/accounts/{account_id}` | Retrieve account details and current balance |
| `PUT` | `/accounts/{account_id}/balance` | *Internal only* -- adjust balance; called by Transaction Service |

**Transaction Service** (`localhost:8001`)

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/health` | Health check -- returns service name and version |
| `POST` | `/transactions` | Create a transaction and trigger a balance update |
| `GET` | `/transactions/{account_id}` | List all transactions for an account |

---

## Running Locally

### Prerequisites

```bash
docker --version        # Docker Desktop must be running
docker compose version  # Should be v2+ (bundled with Docker Desktop)
python3 --version       # Needed for the smoke test script
curl --version
```

### Start the stack

```bash
make run
```

This builds both service images and starts all containers detached. Services come up in dependency order: DynamoDB Local -> table initialisation -> Account Service -> Transaction Service.

Or run directly with Compose:

```bash
docker compose up --build
```

**Access the services:**

| Service | Swagger UI | ReDoc |
| --- | --- | --- |
| Transaction Service | http://localhost:8001/docs | http://localhost:8001/redoc |
| Account Service | http://localhost:8002/docs | http://localhost:8002/redoc |

### Run the end-to-end smoke test

Automated test: create account -> credit -> debit -> verify balance.

```bash
make smoke-test
```

### Try it out

Create an account, move some money around, and check the results.

**1. Create an account** -- note the `account_id` returned (e.g. `acc_4f3a1b2c`), you will use it in every command below.
```bash
curl -s -X POST http://localhost:8002/accounts \
  -H "Content-Type: application/json" \
  -d '{"owner": "Alice", "currency": "EUR"}' | python3 -m json.tool
```

**2. Post some transactions**
```bash
# Credit: salary
curl -s -X POST http://localhost:8001/transactions \
  -H "Content-Type: application/json" \
  -d '{"account_id": "acc_4f3a1b2c", "amount": 3000, "type": "credit", "description": "Salary"}' | python3 -m json.tool

# Debit: groceries
curl -s -X POST http://localhost:8001/transactions \
  -H "Content-Type: application/json" \
  -d '{"account_id": "acc_4f3a1b2c", "amount": 87.50, "type": "debit", "description": "Groceries"}' | python3 -m json.tool

# Debit: rent
curl -s -X POST http://localhost:8001/transactions \
  -H "Content-Type: application/json" \
  -d '{"account_id": "acc_4f3a1b2c", "amount": 1200, "type": "debit", "description": "Rent"}' | python3 -m json.tool
```

**3. Check balance and history**
```bash
curl -s http://localhost:8002/accounts/acc_4f3a1b2c | python3 -m json.tool
curl -s http://localhost:8001/transactions/acc_4f3a1b2c | python3 -m json.tool
```

**4. Watch validation reject bad input**
```bash
# Negative amount -- returns 422
curl -s -X POST http://localhost:8001/transactions \
  -H "Content-Type: application/json" \
  -d '{"account_id": "acc_4f3a1b2c", "amount": -50, "type": "credit"}' | python3 -m json.tool

# Invalid type -- returns 422
curl -s -X POST http://localhost:8001/transactions \
  -H "Content-Type: application/json" \
  -d '{"account_id": "acc_4f3a1b2c", "amount": 50, "type": "transfer"}' | python3 -m json.tool
```

Prefer a browser? The Swagger UI at **http://localhost:8001/docs** and **http://localhost:8002/docs** lets you fire all of the above requests interactively.

### Other useful commands

```bash
make logs       # stream logs from both services
make stop       # stop all containers
make restart    # rebuild images and restart
make clean      # stop containers, remove volumes, clear __pycache__
make help       # list all available targets
```

---

## Deploying to AWS

### Prerequisites

- AWS account with appropriate permissions (EC2, ECS, DynamoDB, IAM, ALB, CloudWatch)
- `terraform` CLI installed and in your `$PATH`
- `docker` installed (for building and pushing images to ECR)
- AWS credentials configured locally (via `~/.aws/credentials` or environment variables)

### Bootstrap

Remote Terraform state is stored in S3 with a DynamoDB lock table. Bootstrap this **once** before any other infrastructure:

```bash
cd infrastructure/terraform/bootstrap
terraform init
terraform apply
```

This creates the S3 bucket and DynamoDB lock table. Store their names -- you will reference them in the next step.

### Deploy infrastructure and services

```bash
cd infrastructure/terraform

# Initialise Terraform with the remote backend
terraform init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="dynamodb_table=<your-lock-table>" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=ap-southeast-2"

# Preview the deployment
make tf-plan

# Apply the deployment
make tf-apply
```

After `apply` completes, Terraform outputs the ALB DNS name:

```bash
terraform output alb_dns_name
```

Then visit `http://<alb-dns-name>/docs` to access the Swagger UI.

### Destroy infrastructure

**Warning: this deletes all resources including data.**

```bash
make tf-destroy
```

---

## Docker

### Images

Both services use a **multi-stage build**. The `builder` stage installs all Python dependencies; only the compiled `site-packages`, the `uvicorn` binary, and the application source are copied into the final runtime image. Build tooling never ships to production.

Both images run as a **non-root user** (`appuser:appgroup`), reducing container escape and privilege escalation risk.

A `HEALTHCHECK` instruction is included in each Dockerfile. Docker Compose uses it to gate service startup order -- the Transaction Service will not start until the Account Service passes its health check.

### Docker Compose (local only)

`docker-compose.yml` defines four containers:

| Container | Image | Purpose |
| --- | --- | --- |
| `dynamodb-local` | `amazon/dynamodb-local` | In-memory DynamoDB stand-in for local development |
| `dynamodb-init` | `amazon/aws-cli` | One-shot container that creates both DynamoDB tables on first start |
| `account-service` | Built locally | Runs the Account Service on port `8002` |
| `transaction-service` | Built locally | Runs the Transaction Service on port `8001` |

The `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` values in `docker-compose.yml` are `"dummy"` placeholders. DynamoDB Local ignores credentials entirely; boto3 requires them to be present syntactically. These values are never used in AWS -- the ECS task role is picked up automatically by the boto3 default credential chain.

---

## Terraform

All AWS infrastructure is defined in [`infrastructure/terraform/`](infrastructure/terraform/).

**What gets provisioned:**

- VPC, subnets, and security groups
- ECR repositories for both service images
- ECS cluster and Fargate task definitions
- Application Load Balancer with listener rules
- DynamoDB tables (`ledgerlite-accounts`, `ledgerlite-transactions`)
- IAM roles and policies (ECS task execution role, task role with DynamoDB access)
- SSM Parameter Store entries for runtime config
- CloudWatch alarms

**Remote state:**

```bash
cd infrastructure/terraform/bootstrap
terraform apply          # Create S3 bucket and DynamoDB lock table
```

Then in the main Terraform directory:

```bash
make tf-plan             # preview changes
make tf-apply            # apply changes
make tf-destroy          # DANGER: destroys all AWS resources including data
```

---

## Repo Layout

```
microledger/
|
+-- account-service/
|   +-- app/
|   |   +-- __init__.py          # Marks app/ as a Python package
|   |   +-- main.py              # FastAPI app -- account CRUD and internal balance endpoint
|   |   +-- database.py          # boto3 DynamoDB resource and table helpers; uses task role in AWS, dummy creds locally
|   |   +-- logger.py            # Structured JSON formatter -- every field queryable in CloudWatch Log Insights
|   +-- Dockerfile               # Multi-stage build; runs as non-root appuser
|   +-- requirements.txt         # fastapi, uvicorn, boto3, pydantic
|
+-- transaction-service/
|   +-- app/
|   |   +-- __init__.py          # Marks app/ as a Python package
|   |   +-- main.py              # FastAPI app -- create and query transactions; calls Account Service for balance updates
|   |   +-- database.py          # boto3 DynamoDB resource and table helpers; uses task role in AWS, dummy creds locally
|   |   +-- logger.py            # Structured JSON formatter -- every field queryable in CloudWatch Log Insights
|   +-- Dockerfile               # Multi-stage build; runs as non-root appuser
|   +-- requirements.txt         # fastapi, uvicorn, boto3, httpx, pydantic
|
+-- infrastructure/
|   +-- terraform/
|       +-- bootstrap/
|       |   +-- main.tf          # S3 bucket and DynamoDB table for remote Terraform state -- apply once before anything else
|       +-- main.tf              # Terraform provider config and backend (S3 + DynamoDB state locking)
|       +-- networking.tf        # VPC, public/private subnets, internet gateway, route tables, security groups
|       +-- ecr.tf               # ECR repositories for account-service and transaction-service images
|       +-- ecs.tf               # ECS cluster, Fargate task definitions, and ECS services
|       +-- alb.tf               # Application Load Balancer, listener, and target group rules
|       +-- dynamodb.tf          # DynamoDB tables for accounts and transactions
|       +-- iam.tf               # ECS task execution role and task role with least-privilege DynamoDB policy
|       +-- ssm.tf               # SSM Parameter Store entries for runtime configuration
|       +-- alarms.tf            # CloudWatch alarms (ECS CPU/memory, DynamoDB errors, ALB 5xx)
|       +-- outputs.tf           # Terraform outputs -- ALB DNS name, ECR URLs, etc.
|       +-- terraform.tfvars.example  # Variable values template -- copy to terraform.tfvars and populate
|
+-- scripts/
|   +-- smoke-test.sh            # End-to-end bash test: create account -> credit -> debit -> assert balance and tx count
|
+-- docker-compose.yml           # Full local stack: DynamoDB Local, table init, account-service, transaction-service
+-- Makefile                     # Developer shortcuts -- run, stop, logs, smoke-test, tf-plan/apply/destroy
+-- .gitignore                   # Excludes .env files, *.tfvars, Terraform state, AWS credentials, and build artefacts
+-- README.md                    # This file
```