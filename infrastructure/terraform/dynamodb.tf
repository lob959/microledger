# =============================================================================
# DynamoDB — Application Tables
# =============================================================================
#
# Amazon DynamoDB is a fully managed, serverless NoSQL key-value and document
# database. Microledger uses two tables: one for account records and one for
# transaction records. There are no EC2 instances, patches, or backups to
# manage — AWS handles all of that.
#
# The table names here exactly match the DYNAMODB_TABLE environment variable
# values set in docker-compose.yml ("microledger-accounts" and
# "microledger-transactions"). This means the same env var values work
# identically in local development and in production without any code changes.
#
# ECS tasks access these tables using the task role defined in iam.tf. The
# task role policy is scoped to these specific table ARNs — tasks cannot
# access any other DynamoDB tables in the account.
# =============================================================================

# ---------------------------------------------------------------------------
# Accounts Table
# ---------------------------------------------------------------------------
# Stores account records: owner name, currency, current balance, and
# timestamps. The account-service reads and writes this table exclusively.
#
# Schema:
#   account_id (S)  — partition key; format: "acc_<8-char-hex>"
#                     All account operations are keyed by account_id, so a
#                     simple hash key is sufficient — no range key needed.
#
# PAY_PER_REQUEST (on-demand) billing:
#   Charges per read and write request rather than requiring you to pre-
#   provision throughput capacity. For a development deployment with variable
#   and unpredictable traffic this is almost always cheaper and eliminates the
#   risk of throttling errors from under-provisioning.
#
# server_side_encryption.enabled = true:
#   Encrypts all data at rest using an AWS-managed KMS key (SSE-AES256) at no
#   extra cost. The key is managed automatically — no key rotation or policy
#   management is required. To use a customer-managed CMK instead, set
#   kms_key_arn to the ARN of your KMS key.

resource "aws_dynamodb_table" "accounts" {
  name         = "microledger-accounts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "account_id"

  attribute {
    name = "account_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "microledger-accounts"
  }
}

# ---------------------------------------------------------------------------
# Transactions Table
# ---------------------------------------------------------------------------
# Stores transaction records: account ID, transaction ID, amount, type
# (credit/debit), optional description, and timestamp. The transaction-service
# reads and writes this table exclusively.
#
# Schema:
#   account_id     (S)  — partition key; groups all transactions for one account
#   transaction_id (S)  — sort key; a UUID assigned at transaction creation
#
# The composite key (partition + sort) models a one-to-many relationship:
# all transactions for a given account share the same partition key, and the
# sort key makes each transaction unique within that partition. The Query API
# then retrieves all transactions for an account in a single request:
#
#   table.query(
#     KeyConditionExpression=Key("account_id").eq(account_id)
#   )
#
# This is the same query issued by GET /transactions/{account_id} in
# transaction-service/app/main.py.

resource "aws_dynamodb_table" "transactions" {
  name         = "microledger-transactions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "account_id"
  range_key    = "transaction_id"

  attribute {
    name = "account_id"
    type = "S"
  }

  attribute {
    name = "transaction_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "microledger-transactions"
  }
}
