# =============================================================================
# CloudWatch Alarms and SNS Notifications
# =============================================================================
#
# CloudWatch Alarms watch a single metric and transition between OK, ALARM,
# and INSUFFICIENT_DATA states based on threshold comparisons. When an alarm
# transitions to ALARM, it sends a notification to the SNS topic below.
#
# After 'terraform apply', subscribe your email address to the SNS topic so
# you receive alarm notifications:
#   AWS Console → SNS → Topics → <topic name> → Create subscription
#   Protocol: Email, Endpoint: your@email.com
# Confirm the subscription via the email AWS sends you.
#
# All ECS alarms require Container Insights to be enabled on the cluster
# (configured in ecs.tf). Without it, the ECS CPU and memory metrics are
# not published to CloudWatch and these alarms will stay in
# INSUFFICIENT_DATA indefinitely.
# =============================================================================

# ---------------------------------------------------------------------------
# SNS Topic — Alert Notifications
# ---------------------------------------------------------------------------
# Amazon Simple Notification Service (SNS) is a publish/subscribe messaging
# service. Each CloudWatch alarm below lists this topic as its alarm_action,
# so when any alarm fires, SNS fans the message out to all subscribers.
#
# The topic itself has no subscribers until you add them manually (or via
# Terraform's aws_sns_topic_subscription if you want to manage it in code).
# Common subscribers: email addresses, Slack (via Lambda), PagerDuty, or
# an ops ticketing system webhook.

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-${var.environment}-alerts"

  tags = {
    Name = "${var.project}-${var.environment}-alerts"
  }
}

# ---------------------------------------------------------------------------
# ECS CPU Alarms
# ---------------------------------------------------------------------------
# ECS Container Insights publishes CPUUtilization as a percentage of the
# vCPU allocated to the task (e.g. 200% of 256 CPU units = 100% of 0.5 vCPU).
#
# evaluation_periods = 2, period = 300 — the alarm only triggers after CPU
# exceeds 70% for two consecutive 5-minute periods (10 minutes total). This
# avoids false alarms from brief CPU spikes during startup or individual
# request bursts. Tune these values if the services have predictable bursty
# workloads.
#
# threshold = 70 — at 256 CPU units (0.25 vCPU), sustained CPU above 70%
# suggests the service is CPU-bound and should either be scaled horizontally
# (increase desired_count) or vertically (increase container_cpu in tfvars).

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_account_service" {
  alarm_name          = "${var.project}-${var.environment}-account-service-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "account-service CPU above 70% for 10 minutes. Consider increasing desired_count or container_cpu."
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.account_service.name
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_transaction_service" {
  alarm_name          = "${var.project}-${var.environment}-transaction-service-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "transaction-service CPU above 70% for 10 minutes. Consider increasing desired_count or container_cpu."
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.transaction_service.name
  }
}

# ---------------------------------------------------------------------------
# ECS Memory Alarms
# ---------------------------------------------------------------------------
# MemoryUtilization is the percentage of the container_memory variable
# currently in use. At 512 MiB, an alert at 80% means ~410 MiB is in use.
#
# Unlike CPU (which can be throttled), memory exhaustion causes the container
# to be OOM-killed and restarted. A memory alarm at 80% gives time to act
# before the task crashes, by either increasing container_memory or
# investigating a memory leak in the application.

resource "aws_cloudwatch_metric_alarm" "ecs_memory_account_service" {
  alarm_name          = "${var.project}-${var.environment}-account-service-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "account-service memory above 80% for 10 minutes. Risk of OOM kill — increase container_memory or investigate leaks."
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.account_service.name
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_transaction_service" {
  alarm_name          = "${var.project}-${var.environment}-transaction-service-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "transaction-service memory above 80% for 10 minutes. Risk of OOM kill — increase container_memory or investigate leaks."
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.transaction_service.name
  }
}

# ---------------------------------------------------------------------------
# ALB 5xx Alarm
# ---------------------------------------------------------------------------
# HTTPCode_ELB_5XX_Count counts HTTP 5xx responses GENERATED BY THE ALB
# itself (e.g. 502 Bad Gateway when no healthy targets exist, 503 Service
# Unavailable when the ALB cannot reach any target). This is different from
# HTTPCode_Target_5XX_Count, which counts 5xx responses from the ECS tasks.
#
# threshold = 10 — more than 10 ALB-originated 5xx responses in a 5-minute
# window is a strong signal that the transaction-service is unhealthy (all
# tasks down, image pull failure, etc.).
#
# treat_missing_data = "notBreaching" — when there is no traffic (e.g. in a
# development environment at night), the metric publishes no data points. This
# setting prevents the alarm from falsely firing due to absence of data.
#
# dimensions.LoadBalancer — must use the ALB's arn_suffix (the portion of the
# ARN after "loadbalancer/"), not the full ARN.

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB generated more than 10 5xx responses in 5 minutes. Check ECS service health and task logs."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
}

# ---------------------------------------------------------------------------
# DynamoDB System Errors Alarm
# ---------------------------------------------------------------------------
# DynamoDB SystemErrors are server-side errors caused by DynamoDB infrastructure
# issues (not application errors like ValidationException or
# ConditionalCheckFailedException). They are rare — AWS guarantees 99.999%
# availability — but any occurrence is worth investigating because the
# application will return 500 errors to clients for the affected requests.
#
# threshold = 0 — alarm on ANY system error (comparison is "greater than 0").
# treat_missing_data = "notBreaching" — no data in a quiet window should not
# trigger an alarm. DynamoDB only publishes this metric when errors occur.
#
# Note: this alarm covers all DynamoDB tables in the account/region. To scope
# it to Microledger tables specifically, add TableName dimensions. However,
# since this is a dedicated AWS account for the project, the broad scope is
# acceptable and catches errors regardless of which table is affected.

resource "aws_cloudwatch_metric_alarm" "dynamodb_system_errors" {
  alarm_name          = "${var.project}-${var.environment}-dynamodb-system-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "SystemErrors"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "DynamoDB system errors detected. These are AWS-side failures — check AWS Service Health Dashboard."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
}
