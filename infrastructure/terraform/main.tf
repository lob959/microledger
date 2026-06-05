# =============================================================================
# Root Module — Provider, Backend, and Input Variables
# =============================================================================
#
# This is the entry point for the main infrastructure stack. It declares the
# AWS provider, configures where Terraform stores its state, and defines the
# input variables shared by all other .tf files in this directory.
#
# All other .tf files in this directory are part of the same root module —
# Terraform reads them all together as a single configuration.
# =============================================================================

terraform {
  required_providers {
    # The AWS provider translates Terraform resource declarations into AWS API
    # calls. Version ~> 5.0 means any 5.x release but not 6.0 or higher,
    # protecting against breaking changes in major versions.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial backend configuration — the bucket name, DynamoDB table name, and
  # state key are supplied at 'terraform init' time via -backend-config flags
  # rather than being hardcoded here. This makes the configuration portable
  # across environments (dev, staging, prod) without editing source files.
  #
  # Full init command (after running the bootstrap module):
  #   terraform init \
  #     -backend-config="bucket=<state-bucket-name>" \
  #     -backend-config="dynamodb_table=ledgerlite-terraform-locks" \
  #     -backend-config="key=ledgerlite/dev/terraform.tfstate" \
  #     -backend-config="region=ap-southeast-2"
  backend "s3" {}
}

# ---------------------------------------------------------------------------
# AWS Provider
# ---------------------------------------------------------------------------
# Configures the AWS SDK used by all resource blocks in this module.
#
# default_tags — every resource created by this provider inherits these tags.
# Tagging at the provider level avoids repeating the same tags on every
# resource and ensures consistent metadata across the entire stack. The tags
# are visible in the AWS console, Cost Explorer, and billing reports.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# Input Variables
# ---------------------------------------------------------------------------
# Variables parameterise the configuration so the same code can deploy
# different environments (dev, staging, prod) by changing values only in
# terraform.tfvars. Copy terraform.tfvars.example to terraform.tfvars and
# override any values you need — that file is gitignored so secrets never
# reach version control.

variable "aws_region" {
  description = "AWS region for all resources. Must match the bootstrap region."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Project name used as a prefix on resource names and tags. Changing this after initial apply will force replacement of most resources."
  type        = string
  default     = "ledgerlite"
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, staging, prod). Used in resource names and tags to distinguish stacks."
  type        = string
  default     = "dev"
}

variable "container_cpu" {
  description = "CPU units for each Fargate task. 256 = 0.25 vCPU, 512 = 0.5 vCPU, 1024 = 1 vCPU. Must be a valid Fargate CPU/memory combination."
  type        = number
  default     = 256
}

variable "container_memory" {
  description = "Memory in MiB for each Fargate task. Must be a valid Fargate CPU/memory combination (e.g. 256 CPU requires 512–2048 MiB)."
  type        = number
  default     = 512
}
