# =============================================================================
# Outputs
# =============================================================================
#
# Outputs are printed to the terminal after 'terraform apply' and are also
# queryable via 'terraform output <name>' or 'terraform output -raw <name>'.
# They are used in the deployment workflow to avoid hardcoding resource names
# in scripts — for example:
#
#   ALB_DNS=$(terraform output -raw alb_dns_name)
#   curl http://${ALB_DNS}/health
#
#   ECR_ACCOUNT=$(terraform output -raw ecr_account_service_url)
#   docker build -t ${ECR_ACCOUNT}:latest ./account-service
#   docker push ${ECR_ACCOUNT}:latest
# =============================================================================

# The public DNS name of the Application Load Balancer. This is the external
# URL for all API requests in production. ECS tasks may take 30-60 seconds
# after 'apply' to become healthy and start receiving traffic.
output "alb_dns_name" {
  description = "Public DNS name of the ALB. Use as the API base URL: curl http://<value>/health"
  value       = aws_lb.main.dns_name
}

# ECR repository URLs for building and pushing Docker images. The full push
# command is: docker push <value>:latest (or :<git-sha> for versioned tags).
output "ecr_account_service_url" {
  description = "ECR repository URL for account-service. Tag and push images here before deploying."
  value       = aws_ecr_repository.account_service.repository_url
}

output "ecr_transaction_service_url" {
  description = "ECR repository URL for transaction-service. Tag and push images here before deploying."
  value       = aws_ecr_repository.transaction_service.repository_url
}

# The VPC ID is useful for diagnosing connectivity issues, creating additional
# resources (e.g. VPC endpoints) in the same VPC, or setting up VPC peering.
output "vpc_id" {
  description = "ID of the VPC containing all stack resources."
  value       = aws_vpc.main.id
}

# The cluster name is used in AWS CLI commands to interact with ECS services,
# for example:
#   aws ecs list-services --cluster <value>
#   aws ecs update-service --cluster <value> --service <name> --force-new-deployment
output "ecs_cluster_name" {
  description = "Name of the ECS cluster. Use with AWS CLI commands targeting ECS services."
  value       = aws_ecs_cluster.main.name
}

# The table names are useful for manual AWS CLI queries during debugging:
#   aws dynamodb scan --table-name <value> --region ap-southeast-2
output "dynamodb_accounts_table_name" {
  description = "Name of the DynamoDB accounts table."
  value       = aws_dynamodb_table.accounts.name
}

output "dynamodb_transactions_table_name" {
  description = "Name of the DynamoDB transactions table."
  value       = aws_dynamodb_table.transactions.name
}

# Subscribe your on-call email to this topic after the first apply so you
# receive CloudWatch alarm notifications. In the AWS console:
#   SNS → Topics → <topic name> → Create subscription → Email
output "sns_alerts_topic_arn" {
  description = "ARN of the CloudWatch alerts SNS topic. Subscribe an email address to receive alarm notifications."
  value       = aws_sns_topic.alerts.arn
}
