import os
import uuid
from decimal import Decimal
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from app.database import get_table
from app.logger import get_logger

logger = get_logger(__name__)

app = FastAPI(
    title="LedgerLite — Account Service",
    version=os.getenv("APP_VERSION", "local"),
    description="Manages accounts and running balances. Balance updates are made by the Transaction Service via an internal endpoint not exposed on the ALB.",
)


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------

class CreateAccountRequest(BaseModel):
    owner: str = Field(min_length=1, max_length=100)
    currency: str = Field(default="EUR", pattern=r"^[A-Z]{3}$", description="ISO 4217 currency code")


class BalanceAdjustmentRequest(BaseModel):
    """
    Called internally by the Transaction Service only.
    Positive adjustment = credit, negative = debit.
    """
    adjustment: float = Field(ne=0, description="Non-zero balance adjustment")


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health", tags=["ops"])
def health():
    """ALB health check target."""
    return {
        "status": "ok",
        "service": "account-service",
        "version": os.getenv("APP_VERSION", "local"),
    }


@app.post("/accounts", status_code=201, tags=["accounts"])
def create_account(request: CreateAccountRequest):
    """
    Create a new account with a zero starting balance.
    Returns the generated account_id — store this to create transactions.
    """
    account_id = f"acc_{uuid.uuid4().hex[:8]}"
    created_at = datetime.now(timezone.utc).isoformat()
    table_name = os.getenv("DYNAMODB_TABLE", "ledgerlite-accounts")

    item = {
        "account_id": account_id,
        "owner": request.owner,
        "currency": request.currency,
        "balance": Decimal("0"),
        "created_at": created_at,
        "updated_at": created_at,
    }

    try:
        table = get_table(table_name)
        table.put_item(Item=item)
        logger.info(
            "Account created",
            extra={"account_id": account_id, "owner": request.owner, "currency": request.currency},
        )
    except Exception as exc:
        logger.error("Failed to create account", extra={"error": str(exc)})
        raise HTTPException(status_code=500, detail="Failed to create account")

    return {
        "account_id": account_id,
        "owner": request.owner,
        "currency": request.currency,
        "balance": 0.0,
        "created_at": created_at,
        "updated_at": created_at,
    }


@app.get("/accounts/{account_id}", tags=["accounts"])
def get_account(account_id: str):
    """Return account details and current balance."""
    table_name = os.getenv("DYNAMODB_TABLE", "ledgerlite-accounts")

    try:
        table = get_table(table_name)
        response = table.get_item(Key={"account_id": account_id})
    except Exception as exc:
        logger.error(
            "DynamoDB get_item failed",
            extra={"error": str(exc), "account_id": account_id},
        )
        raise HTTPException(status_code=500, detail="Failed to retrieve account")

    item = response.get("Item")
    if not item:
        logger.warning("Account not found", extra={"account_id": account_id})
        raise HTTPException(status_code=404, detail=f"Account '{account_id}' not found")

    return {
        "account_id": item["account_id"],
        "owner": item["owner"],
        "currency": item["currency"],
        "balance": float(item["balance"]),
        "created_at": item["created_at"],
        "updated_at": item["updated_at"],
    }


@app.put("/accounts/{account_id}/balance", tags=["internal"])
def update_balance(account_id: str, request: BalanceAdjustmentRequest):
    """
    INTERNAL ENDPOINT — adjust account balance by the given amount.

    This is called by the Transaction Service and is intentionally NOT exposed
    via the public ALB listener rules. It is only reachable from within the VPC.

    Uses a DynamoDB conditional update so the write is rejected cleanly if the
    account does not exist, rather than silently creating a partial record.
    """
    table_name = os.getenv("DYNAMODB_TABLE", "ledgerlite-accounts")
    updated_at = datetime.now(timezone.utc).isoformat()

    try:
        table = get_table(table_name)
        response = table.update_item(
            Key={"account_id": account_id},
            # Atomically add the adjustment to the existing balance
            UpdateExpression="SET balance = balance + :adj, updated_at = :ts",
            ExpressionAttributeValues={
                ":adj": Decimal(str(request.adjustment)),
                ":ts": updated_at,
            },
            # Guard: reject if the account row doesn't already exist
            ConditionExpression="attribute_exists(account_id)",
            ReturnValues="UPDATED_NEW",
        )
    except Exception as exc:
        error_code = getattr(exc, "response", {}).get("Error", {}).get("Code", "")

        if error_code == "ConditionalCheckFailedException":
            logger.warning(
                "Balance update rejected — account does not exist",
                extra={"account_id": account_id},
            )
            raise HTTPException(status_code=404, detail=f"Account '{account_id}' not found")

        logger.error(
            "DynamoDB update_item failed",
            extra={"error": str(exc), "account_id": account_id},
        )
        raise HTTPException(status_code=500, detail="Failed to update balance")

    new_balance = float(response["Attributes"]["balance"])

    logger.info(
        "Balance updated",
        extra={
            "account_id": account_id,
            "adjustment": request.adjustment,
            "new_balance": new_balance,
        },
    )

    return {
        "account_id": account_id,
        "new_balance": new_balance,
        "updated_at": updated_at,
    }