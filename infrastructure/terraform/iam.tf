# =============================================================================
# IAM — Roles and Policies for ECS Tasks
# =============================================================================
#
# ECS Fargate tasks use two separate IAM roles with distinct responsibilities:
#
# 1. Task Execution Role (ecs_task_execution)
#    Used by the ECS AGENT — the AWS-managed process that runs alongside the
#    container on the Fargate infrastructure. It needs permissions to:
#      - Pull the Docker image from ECR before the container starts
#      - Write the container's stdout/stderr to CloudWatch Logs
#      - Fetch SSM parameters to inject as environment variables at startup
#
# 2. Task Role (ecs_task)
#    Used by the APPLICATION CODE running inside the container. boto3 picks
#    up this role automatically via the ECS metadata endpoint. It needs
#    permissions to read and write DynamoDB tables — nothing else.
#
# Separating these roles follows the principle of least privilege: the
# container process never has ECR or CloudWatch write access, and the ECS
# agent never has DynamoDB access. A compromised container cannot escalate
# to overwrite its own image or exfiltrate logs from other services.
# =============================================================================

# ---------------------------------------------------------------------------
# Shared Trust Policy
# ---------------------------------------------------------------------------
# A trust policy defines which AWS principal is allowed to assume (i.e. take
# on the identity of) this role. Both roles below are assumed by the ECS tasks
# service, so they share the same trust document.
#
# Without this trust policy, no entity could use the role — it would exist in
# IAM but be effectively inert. The "sts:AssumeRole" action is the mechanism
# by which the ECS service exchanges its own identity for the role's credentials
# when starting a task.

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Task Execution Role
# ---------------------------------------------------------------------------
# This role is specified in the task definition as "executionRoleArn". The ECS
# agent on the Fargate infrastructure assumes it before the container starts,
# so it can perform the setup steps the container itself cannot do: pulling the
# image and creating the log stream.

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project}-${var.environment}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

# ---------------------------------------------------------------------------
# Task Execution Role — AWS Managed Policy
# ---------------------------------------------------------------------------
# AmazonECSTaskExecutionRolePolicy is an AWS-maintained managed policy that
# grants the minimum permissions for:
#   - ecr:GetAuthorizationToken — authenticate to ECR before pulling
#   - ecr:BatchCheckLayerAvailability, ecr:GetDownloadUrlForLayer,
#     ecr:BatchGetImage — pull image layers from the repository
#   - logs:CreateLogStream, logs:PutLogEvents — write container logs to the
#     CloudWatch Log Group declared in ecs.tf
#
# Using the managed policy (rather than writing the same permissions inline)
# means AWS will update it if new ECS features require additional permissions.

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------------------------------------------------------------------------
# Task Execution Role — SSM Parameter Access
# ---------------------------------------------------------------------------
# The task definitions in ecs.tf can inject SSM parameters as environment
# variables at container startup. ECS fetches those parameters using the
# execution role (not the task role), so this inline policy grants
# GetParameters access scoped to the /microledger/* parameter path only.
# Tasks from a different project cannot read Microledger's parameters.

resource "aws_iam_role_policy" "ecs_task_execution_ssm" {
  name = "ssm-read"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project}/*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Task Role
# ---------------------------------------------------------------------------
# This role is specified in the task definition as "taskRoleArn". The running
# container process assumes it when it makes any AWS API call. boto3 discovers
# it automatically via the ECS task metadata endpoint without any credential
# configuration in the application code.
#
# The task role has no managed policies attached — only the minimal inline
# DynamoDB policy below. This means a compromised container can only affect
# the two DynamoDB tables explicitly listed.

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project}-${var.environment}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

# ---------------------------------------------------------------------------
# Task Role — DynamoDB Least-Privilege Policy
# ---------------------------------------------------------------------------
# Grants only the five DynamoDB actions actually used by the application code,
# scoped to the two specific table ARNs declared in dynamodb.tf. Any attempt
# by the application to access a different table, perform a Scan, or call any
# other AWS service will return an AccessDeniedException.
#
# GetItem     — account-service GET /accounts/{id}
# PutItem     — account-service POST /accounts (create new record)
# UpdateItem  — account-service PUT /accounts/{id}/balance (balance adjustment)
# Query       — transaction-service GET /transactions/{account_id}
# DescribeTable — boto3 metadata call made during table initialisation

resource "aws_iam_role_policy" "ecs_task_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:DescribeTable"
        ]
        Resource = [
          aws_dynamodb_table.accounts.arn,
          aws_dynamodb_table.transactions.arn
        ]
      }
    ]
  })
}
