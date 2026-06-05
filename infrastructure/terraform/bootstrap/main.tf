# =============================================================================
# Bootstrap — Remote State Backend
# =============================================================================
#
# This configuration is applied ONCE before the main infrastructure stack.
# It creates the S3 bucket and DynamoDB table that Terraform uses to store
# and lock its state file. Without this, Terraform can only use local state,
# which cannot be shared between team members or CI/CD pipelines.
#
# Apply this first:
#   cd infrastructure/terraform/bootstrap
#   terraform init
#   terraform apply
#
# Then note the two output values and pass them to the main stack init:
#   terraform init \
#     -backend-config="bucket=<state_bucket_name>" \
#     -backend-config="dynamodb_table=<state_lock_table_name>" \
#     ...
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

# Resolves the AWS account ID at apply time. Used to make the S3 bucket name
# globally unique without any manual input — S3 bucket names must be unique
# across all AWS accounts worldwide.
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# S3 Bucket — Terraform State Storage
# ---------------------------------------------------------------------------
# Terraform state (terraform.tfstate) records every resource it manages and
# their current attribute values. Storing it in S3 makes the state accessible
# to all team members and CI/CD pipelines regardless of where 'terraform apply'
# is run. Storing it locally is only viable for solo development.
#
# The bucket name embeds the AWS account ID (e.g. "microledger-tfstate-123456789012")
# to guarantee global uniqueness without configuration.
#
# lifecycle prevent_destroy = true — 'terraform destroy' will refuse to delete
# this bucket even if requested. Destroying the state bucket permanently loses
# the record of all managed infrastructure, making future applies unpredictable.
# To actually delete the bucket, remove this block and re-plan first.

resource "aws_s3_bucket" "terraform_state" {
  bucket = "microledger-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = false
  }
  tags = {
    Name    = "microledger-tfstate"
    Service = "bootstrap"
  }
}

# ---------------------------------------------------------------------------
# S3 Bucket Versioning
# ---------------------------------------------------------------------------
# Versioning retains every previous version of the state file. This makes it
# possible to roll back to an earlier state if a bad apply corrupts the current
# one. Without versioning, an accidentally deleted or overwritten state file
# cannot be recovered.

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------------------
# S3 Bucket Server-Side Encryption
# ---------------------------------------------------------------------------
# The state file can contain sensitive resource metadata such as resource ARNs,
# security group IDs, and (if secrets were incorrectly stored in variables)
# plaintext values. AES256 encryption ensures the file is encrypted at rest
# using an AWS-managed key at no extra cost.

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# S3 Bucket Public Access Block
# ---------------------------------------------------------------------------
# State files must never be publicly accessible — they describe your entire
# infrastructure in detail. These four flags collectively prevent any public
# ACL or bucket policy from accidentally making the bucket or its objects
# readable by the internet, even if someone misconfigures a bucket policy.

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DynamoDB Table — State Locking
# ---------------------------------------------------------------------------
# When multiple engineers or CI/CD pipelines run 'terraform apply' at the
# same time against the same state file, they can overwrite each other's
# changes. The DynamoDB lock table prevents this: Terraform writes a lock
# record before it reads state and releases it after writing. Any concurrent
# run that tries to acquire the lock will wait or fail with a clear error.
#
# hash_key = "LockID" — the key Terraform uses internally; do not change.
# PAY_PER_REQUEST — the table is only accessed during 'terraform plan/apply',
# which is infrequent, so on-demand billing is far cheaper than provisioned.

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "microledger-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
  tags = {
    Name    = "microledger-terraform-locks"
    Service = "bootstrap"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
# These values are printed after 'terraform apply' and must be passed to the
# main stack's 'terraform init' command via -backend-config flags.
# See the "Bootstrap" section in the project README for the exact command.

output "state_bucket_name" {
  description = "S3 bucket for Terraform remote state. Pass to: terraform init -backend-config=\"bucket=<value>\"."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_lock_table_name" {
  description = "DynamoDB lock table. Pass to: terraform init -backend-config=\"dynamodb_table=<value>\"."
  value       = aws_dynamodb_table.terraform_locks.name
}
