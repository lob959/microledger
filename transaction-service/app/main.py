import os
import uuid
from decimal import Decimal
from datetime import datetime, timezone
from typing import Literal, Optional

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from boto3.dynamodb.conditions import Key

from app.database import get_table
from app.logger import get_logger

logger = get_logger(__name__)

app = FastAPI(
    title="LedgerLite — Transaction Service",
    version=os.getenv("APP_VERSION", "local"),
    description="Creates and retrieves financial transactions. Calls the Account Service to update balances.",
)


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------

class TransactionRequest(BaseModel):
    account_id: str
    amount: float = Field(gt=0, description="Transaction amount — must be greater than 0")
    type: Literal["credit", "debit"]
    description: Optional[str] = ""


class TransactionResponse(BaseModel):
    transaction_id: str
    account_id: str
    amount: float
    type: str
    description: str
    created_at: str


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health", tags=["ops"])
def health():
    """
    ALB health check target. Returns service name and deployed version.
    The version is the Git SHA injected by GitHub Actions — useful for
    confirming exactly which build is running without opening the console.
    """
    return {
        "status": "ok",
        "service": "transaction-service",
        "version": os.getenv("APP_VERSION", "local"),
    }


@app.post("/transactions", response_model=TransactionResponse, status_code=201, tags=["transactions"])
async def create_transaction(transaction: TransactionRequest):
    """
    Create a new transaction and update the account balance.

    Flow:
      1. Write the transaction record to DynamoDB.
      2. Call the Account Service (internal ALB path) to adjust the balance.

    If the Account Service call fails the transaction record is still written —
    in a production system you would add a DynamoDB Stream or SQS dead-letter
    queue to reconcile this. For now the inconsistency is logged clearly.
    """
    transaction_id = str(uuid.uuid4())
    created_at = datetime.now(timezone.utc).isoformat()
    table_name = os.getenv("DYNAMODB_TABLE", "ledgerlite-transactions")

    # ---- 1. Write transaction to DynamoDB --------------------------------
    item = {
        "account_id": transaction.account_id,
        "transaction_id": transaction_id,
        # DynamoDB does not accept Python floats — store as Decimal via string
        "amount": Decimal(str(transaction.amount)),
        "type": transaction.type,
        "description": transaction.description or "",
        "created_at": created_at,
    }

    try:
        table = get_table(table_name)
        table.put_item(Item=item)
        logger.info(
            "Transaction written to DynamoDB",
            extra={
                "transaction_id": transaction_id,
                "account_id": transaction.account_id,
                "amount": transaction.amount,
                "type": transaction.type,
            },
        )
    except Exception as exc:
        logger.error(
            "DynamoDB write failed",
            extra={"error": str(exc), "account_id": transaction.account_id},
        )
        raise HTTPException(status_code=500, detail="Failed to persist transaction")

    # ---- 2. Notify Account Service ---------------------------------------
    account_service_url = os.getenv("ACCOUNT_SERVICE_URL", "http://localhost:8002")
    # Credits increase balance, debits decrease it
    adjustment = transaction.amount if transaction.type == "credit" else -transaction.amount

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.put(
                f"{account_service_url}/accounts/{transaction.account_id}/balance",
                json={"adjustment": adjustment},
            )
            response.raise_for_status()

        logger.info(
            "Account balance updated",
            extra={
                "transaction_id": transaction_id,
                "account_id": transaction.account_id,
                "adjustment": adjustment,
            },
        )

    except httpx.HTTPStatusError as exc:
        logger.error(
            "Account Service returned an error — balance may be inconsistent",
            extra={
                "transaction_id": transaction_id,
                "account_id": transaction.account_id,
                "status_code": exc.response.status_code,
                "response_body": exc.response.text,
            },
        )
        raise HTTPException(status_code=502, detail="Account Service rejected the balance update")

    except Exception as exc:
        logger.error(
            "Could not reach Account Service — balance may be inconsistent",
            extra={
                "transaction_id": transaction_id,
                "account_id": transaction.account_id,
                "error": str(exc),
            },
        )
        raise HTTPException(status_code=502, detail="Account Service unavailable")

    return TransactionResponse(
        transaction_id=transaction_id,
        account_id=transaction.account_id,
        amount=transaction.amount,
        type=transaction.type,
        description=transaction.description or "",
        created_at=created_at,
    )


@app.get("/transactions/{account_id}", tags=["transactions"])
async def get_transactions(account_id: str):
    """
    Return all transactions for a given account, sorted by DynamoDB sort key
    (transaction_id / insert order). For large datasets add pagination via
    ExclusiveStartKey — left as a future enhancement.
    """
    table_name = os.getenv("DYNAMODB_TABLE", "ledgerlite-transactions")

    try:
        table = get_table(table_name)
        response = table.query(
            KeyConditionExpression=Key("account_id").eq(account_id)
        )
    except Exception as exc:
        logger.error(
            "DynamoDB query failed",
            extra={"error": str(exc), "account_id": account_id},
        )
        raise HTTPException(status_code=500, detail="Failed to retrieve transactions")

    items = response.get("Items", [])

    # Convert Decimal → float so FastAPI can serialise to JSON
    for item in items:
        item["amount"] = float(item["amount"])

    logger.info(
        "Transactions retrieved",
        extra={"account_id": account_id, "count": len(items)},
    )

    return {
        "account_id": account_id,
        "count": len(items),
        "transactions": items,
    }