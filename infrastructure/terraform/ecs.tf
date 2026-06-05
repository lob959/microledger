# =============================================================================
# ECS — Elastic Container Service (Fargate)
# =============================================================================
#
# ECS is AWS's container orchestration service. It runs Docker containers
# without requiring you to provision or manage EC2 instances. The Fargate
# launch type extends this further — AWS manages the underlying compute
# infrastructure entirely; you only specify CPU and memory per task.
#
# This file provisions:
#   - One ECS cluster that groups both services
#   - Two CloudWatch Log Groups (one per service) for structured JSON logs
#   - A Cloud Map private DNS namespace for service-to-service discovery
#   - Two ECS task definitions describing what container to run and how
#   - Two ECS services that keep the task definitions running continuously
#
# Architecture reminder:
#   Internet → ALB → transaction-service (private subnet)
#                         ↓  (Cloud Map DNS)
#                    account-service (private subnet)
#                         ↓
#                      DynamoDB
# =============================================================================

# ---------------------------------------------------------------------------
# ECS Cluster
# ---------------------------------------------------------------------------
# A cluster is a logical grouping of tasks and services. It provides a
# namespace for resource names and a boundary for Container Insights metrics.
# Both services (account and transaction) run in this single cluster.
#
# containerInsights = "enabled" — enables CloudWatch Container Insights, which
# collects CPU, memory, network, and disk metrics per service and task. Metrics
# appear under the "ECS/ContainerInsights" CloudWatch namespace and are used
# by the alarms in alarms.tf. Without this setting, ECS service-level metrics
# are not published and the alarms would have no data to evaluate.

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.project}-${var.environment}-cluster"
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups
# ---------------------------------------------------------------------------
# ECS tasks write container stdout/stderr to CloudWatch Logs using the
# "awslogs" log driver configured in each task definition below. Log groups
# are the top-level containers in CloudWatch Logs; log streams are created
# automatically per task (one stream per task launch).
#
# The structured JSON formatter in logger.py (shared by both services) writes
# every log line as a single JSON object. This makes the logs queryable with
# CloudWatch Log Insights:
#
#   fields @timestamp, message, account_id, level
#   | filter service = "transaction-service"
#   | sort @timestamp desc
#
# retention_in_days = 14 — logs older than 14 days are deleted automatically.
# Adjust to meet your compliance requirements; 0 means retain indefinitely
# (which can lead to unbounded storage costs).

resource "aws_cloudwatch_log_group" "account_service" {
  name              = "/ecs/${var.project}/account-service"
  retention_in_days = 14

  tags = {
    Name = "/ecs/${var.project}/account-service"
  }
}

resource "aws_cloudwatch_log_group" "transaction_service" {
  name              = "/ecs/${var.project}/transaction-service"
  retention_in_days = 14

  tags = {
    Name = "/ecs/${var.project}/transaction-service"
  }
}

# ---------------------------------------------------------------------------
# Cloud Map — Private DNS Namespace
# ---------------------------------------------------------------------------
# AWS Cloud Map is a service discovery service. This resource creates a
# private DNS zone named "microledger.local" that is resolvable only from
# within the VPC (not from the internet).
#
# When the account-service ECS service starts a task, it registers the task's
# private IP as an A record in this namespace under the "account-service"
# service name. The result is that any other ECS task in the VPC can reach
# account-service at:
#
#   http://account-service.microledger.local:8000
#
# This is the value of the ACCOUNT_SERVICE_URL environment variable injected
# into the transaction-service task definition below. No hard-coded IP
# addresses are needed, and if a task is replaced (e.g. during a deployment
# or after a health check failure), the DNS record is updated automatically.
#
# vpc = aws_vpc.main.id — the namespace is private to this VPC. Tasks in other
# VPCs cannot resolve microledger.local, even if they are in the same account.

resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.project}.local"
  description = "Private service discovery for ${var.project} (${var.environment})"
  vpc         = aws_vpc.main.id

  tags = {
    Name = "${var.project}.local"
  }
}

# ---------------------------------------------------------------------------
# Cloud Map — account-service Service Registration
# ---------------------------------------------------------------------------
# A Cloud Map "service" is the named endpoint within the namespace. When an
# ECS task registers, it creates one A record of type "account-service" in
# the "microledger.local" namespace, resolving to the task's private IP.
#
# dns_records.type = "A" — registers IPv4 addresses (the private IPs of
# Fargate task ENIs).
#
# dns_records.ttl = 10 — DNS clients cache the IP for only 10 seconds. A low
# TTL means that if a task is replaced, callers will discover the new IP
# within 10 seconds. A higher TTL reduces DNS query overhead but slows
# failover.
#
# routing_policy = "MULTIVALUE" — if desired_count is increased above 1, Cloud
# Map returns all healthy task IPs in the DNS response and the caller's DNS
# client picks one at random. This provides basic load distribution without
# an internal ALB.
#
# health_check_custom_config.failure_threshold = 1 — ECS notifies Cloud Map
# when a task becomes unhealthy (via the task health check). After 1 failure
# report, Cloud Map stops returning that task's IP in DNS responses.

resource "aws_service_discovery_service" "account_service" {
  name = "account-service"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ---------------------------------------------------------------------------
# Task Definition — account-service
# ---------------------------------------------------------------------------
# A task definition is an immutable, versioned blueprint that describes how to
# run one or more containers. Every time you push a new image or change the
# configuration, ECS creates a new revision. The ECS service then rolls tasks
# to the new revision.
#
# network_mode = "awsvpc" — required for Fargate. Each task gets its own
# Elastic Network Interface (ENI) with a private IP address drawn from the
# subnet CIDR. This is why the ALB target group uses target_type = "ip".
#
# requires_compatibilities = ["FARGATE"] — restricts this task definition to
# the Fargate launch type. EC2 launch type tasks use different CPU/memory
# values and scheduling logic.
#
# execution_role_arn — the task EXECUTION role (for the ECS agent: ECR pull,
# CloudWatch logs, SSM parameter fetch). Declared in iam.tf.
#
# task_role_arn — the task role (for the APPLICATION CODE: DynamoDB access).
# The container's boto3 client picks this up automatically from the ECS
# metadata endpoint. Declared in iam.tf.
#
# container_definitions.environment — environment variables injected at task
# start. DYNAMODB_TABLE is read by database.py; the others are read by main.py
# and logger.py. AWS_REGION is explicitly set so boto3 does not need to call
# the EC2 metadata service to discover the region.

resource "aws_ecs_task_definition" "account_service" {
  family                   = "${var.project}-${var.environment}-account-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "account-service"
      image     = "${aws_ecr_repository.account_service.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "DYNAMODB_TABLE", value = aws_dynamodb_table.accounts.name },
        { name = "AWS_REGION",     value = var.aws_region },
        { name = "LOG_LEVEL",      value = "INFO" },
        { name = "SERVICE_NAME",   value = "account-service" },
        { name = "APP_VERSION",    value = "latest" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.account_service.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project}-${var.environment}-account-service"
  }
}

# ---------------------------------------------------------------------------
# Task Definition — transaction-service
# ---------------------------------------------------------------------------
# Identical structure to the account-service task definition above. The key
# differences are:
#
# ACCOUNT_SERVICE_URL — injected as an environment variable pointing to the
# Cloud Map DNS name "http://account-service.microledger.local:8000". The
# transaction-service main.py uses this URL in httpx.AsyncClient calls to
# invoke POST /accounts/{id}/balance after recording each transaction.
#
# DYNAMODB_TABLE — points to the transactions table, not the accounts table.
# Each service only knows about its own table; the DynamoDB task role policy
# in iam.tf grants access to both tables because both services share the same
# task role.

resource "aws_ecs_task_definition" "transaction_service" {
  family                   = "${var.project}-${var.environment}-transaction-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "transaction-service"
      image     = "${aws_ecr_repository.transaction_service.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "DYNAMODB_TABLE",      value = aws_dynamodb_table.transactions.name },
        { name = "AWS_REGION",          value = var.aws_region },
        { name = "LOG_LEVEL",           value = "INFO" },
        { name = "SERVICE_NAME",        value = "transaction-service" },
        { name = "APP_VERSION",         value = "latest" },
        { name = "ACCOUNT_SERVICE_URL", value = "http://account-service.${var.project}.local:8000" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.transaction_service.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project}-${var.environment}-transaction-service"
  }
}

# ---------------------------------------------------------------------------
# ECS Service — account-service
# ---------------------------------------------------------------------------
# An ECS service ensures that the specified number of task instances run
# continuously. If a task fails its health check or the underlying Fargate
# infrastructure has a problem, ECS automatically replaces it.
#
# desired_count = 1 — run one task at a time. Increase this for higher
# availability. With the MULTIVALUE Cloud Map routing policy, multiple tasks
# would be discovered by DNS-based load balancing.
#
# launch_type = "FARGATE" — AWS manages the compute; no EC2 to patch.
#
# network_configuration.subnets — tasks run in the private subnets so they
# have no direct internet exposure. They reach AWS services via the NAT GW.
#
# network_configuration.assign_public_ip = false — tasks do not receive public
# IPs, reinforcing the private-subnet isolation.
#
# service_registries — registers each task's private IP with the Cloud Map
# service declared above. This creates the A record that resolves
# "account-service.microledger.local" to the task's IP.
#
# lifecycle.ignore_changes = [task_definition] — Terraform sets the initial
# task definition revision when it first creates the service. After that, the
# CI/CD pipeline pushes a new image, creates a new task definition revision,
# and updates the service via the AWS CLI or API. If Terraform managed the
# task_definition attribute, the next 'terraform apply' would revert the
# service to the Terraform-managed revision, undoing the CI deployment.

resource "aws_ecs_service" "account_service" {
  name            = "${var.project}-${var.environment}-account-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.account_service.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.account_service.arn
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = {
    Name = "${var.project}-${var.environment}-account-service"
  }
}

# ---------------------------------------------------------------------------
# ECS Service — transaction-service
# ---------------------------------------------------------------------------
# Same structure as the account-service ECS service above, with two additions:
#
# load_balancer block — registers the transaction-service tasks with the ALB
# target group declared in alb.tf. When a new task starts, ECS calls the ALB
# API to add the task's private IP:8000 as a target. When a task stops, ECS
# deregisters it. The ALB then routes HTTP requests from the internet to the
# healthy registered tasks.
#
# container_name = "transaction-service" and container_port = 8000 — must
# match the name and portMappings in the task definition above.
#
# depends_on = [aws_lb_listener.http] — the listener must exist before ECS
# attempts to register targets with the target group. Without this dependency,
# Terraform might create the ECS service (which immediately tries to register
# with the ALB) before the listener is attached, causing an API error.

resource "aws_ecs_service" "transaction_service" {
  name            = "${var.project}-${var.environment}-transaction-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.transaction_service.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.transaction_service.arn
    container_name   = "transaction-service"
    container_port   = 8000
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http]

  tags = {
    Name = "${var.project}-${var.environment}-transaction-service"
  }
}
