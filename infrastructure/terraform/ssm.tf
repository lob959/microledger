# =============================================================================
# SSM Parameter Store — Runtime Configuration
# =============================================================================
#
# AWS Systems Manager Parameter Store provides a secure, hierarchical store for
# configuration data. Storing configuration here (rather than hardcoding it in
# task definitions or Dockerfiles) provides two benefits:
#
# 1. Single source of truth — the CI/CD pipeline can update the app-version
#    parameter on each successful image push without touching Terraform, so a
#    deploy is a single SSM write followed by an ECS task replacement.
#
# 2. Auditability — Parameter Store records every change with a timestamp and
#    the IAM principal that made it, providing a full change history.
#
# The task execution role in iam.tf grants ECS the ssm:GetParameters permission
# for paths under /${var.project}/* so these values are injected as environment
# variables before the container starts. The application code reads them via
# os.getenv() and never needs to call the SSM API directly.
#
# All parameters use Type = "String" (not SecureString) because the values
# here are not secrets — they are service discovery URLs and log config. Use
# SecureString (backed by KMS) for database passwords, API keys, or other
# credentials if added in future.
# =============================================================================

# ---------------------------------------------------------------------------
# Account Service URL
# ---------------------------------------------------------------------------
# The internal DNS name that the transaction-service uses to call the
# account-service's balance endpoint. This value uses the Cloud Map private
# DNS name registered in ecs.tf: "account-service.microledger.local".
#
# The DNS name resolves only within the VPC — it is not accessible from the
# internet. Cloud Map registers one A record per running task, so DNS-based
# load balancing distributes requests if desired_count is increased above 1.
#
# This parameter is referenced by the transaction-service task definition in
# ecs.tf as the ACCOUNT_SERVICE_URL environment variable.

resource "aws_ssm_parameter" "account_service_url" {
  name  = "/${var.project}/${var.environment}/account-service-url"
  type  = "String"
  value = "http://account-service.${var.project}.local:8000"

  tags = {
    Name = "${var.project}-${var.environment}-account-service-url"
  }
}

# ---------------------------------------------------------------------------
# Log Level
# ---------------------------------------------------------------------------
# Controls the verbosity of structured JSON logs emitted to CloudWatch Logs.
# The application code reads LOG_LEVEL via os.getenv() in logger.py.
# Valid values: DEBUG, INFO, WARNING, ERROR, CRITICAL (standard Python levels).
# Set to DEBUG to see full request/response details during troubleshooting.

resource "aws_ssm_parameter" "log_level" {
  name  = "/${var.project}/${var.environment}/log-level"
  type  = "String"
  value = "INFO"

  tags = {
    Name = "${var.project}-${var.environment}-log-level"
  }
}

# ---------------------------------------------------------------------------
# App Version
# ---------------------------------------------------------------------------
# The version string injected into each container as APP_VERSION and included
# in every structured log line and health check response. This makes it easy
# to correlate logs with the deployed image version in CloudWatch Log Insights.
#
# lifecycle ignore_changes = [value] — Terraform sets the initial value to
# "latest" but then ignores future changes. The CI/CD pipeline is responsible
# for updating this parameter to the Git SHA or semantic version tag on each
# successful deployment. If Terraform were to manage the value, a 'terraform
# apply' during a deploy could revert it to "latest".

resource "aws_ssm_parameter" "app_version" {
  name  = "/${var.project}/${var.environment}/app-version"
  type  = "String"
  value = "latest"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${var.project}-${var.environment}-app-version"
  }
}
