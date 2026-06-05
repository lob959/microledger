# =============================================================================
# ECR — Elastic Container Registry
# =============================================================================
#
# ECR is a fully managed private Docker image registry hosted by AWS. Each ECS
# Fargate task definition references an image stored here; ECS pulls the image
# when starting a task. Using ECR instead of Docker Hub avoids rate limits,
# keeps images in the same region as the ECS cluster (no egress costs), and
# integrates with IAM for access control — no separate registry credentials
# are needed.
#
# The task execution role (defined in iam.tf) is granted ECR pull access via
# the AmazonECSTaskExecutionRolePolicy managed policy, so ECS can pull images
# automatically when it starts tasks.
#
# Before running 'terraform apply' on the main stack for the first time, push
# images to these repositories so ECS has something to pull:
#
#   # Authenticate Docker to ECR
#   aws ecr get-login-password --region ap-southeast-2 | \
#     docker login --username AWS --password-stdin \
#     <account-id>.dkr.ecr.ap-southeast-2.amazonaws.com
#
#   # Build and push account-service
#   docker build -t <ecr_account_service_url>:latest ./account-service
#   docker push <ecr_account_service_url>:latest
#
#   # Build and push transaction-service
#   docker build -t <ecr_transaction_service_url>:latest ./transaction-service
#   docker push <ecr_transaction_service_url>:latest
#
# The ECR repository URLs are available as Terraform outputs after apply.
# =============================================================================

# ---------------------------------------------------------------------------
# ECR Repository — account-service
# ---------------------------------------------------------------------------
# Stores versioned Docker images for the account-service. The repository name
# uses a namespace prefix (ledgerlite/account-service) to group both service
# images together in the ECR console.
#
# image_tag_mutability = "MUTABLE" — allows the :latest tag to be overwritten
# on each new build, which is the simplest workflow for this project. In a
# stricter environment you would use "IMMUTABLE" and always deploy by SHA tag.
#
# scan_on_push = true — ECR automatically scans each pushed image for known
# OS-level CVEs using Amazon Inspector. Scan results appear in the ECR console
# and can be queried by CI/CD pipelines to gate deployments on severity.

resource "aws_ecr_repository" "account_service" {
  name                 = "${var.project}/account-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project}/account-service"
  }
}

# ---------------------------------------------------------------------------
# ECR Repository — transaction-service
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "transaction_service" {
  name                 = "${var.project}/transaction-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project}/transaction-service"
  }
}

# ---------------------------------------------------------------------------
# ECR Lifecycle Policies
# ---------------------------------------------------------------------------
# Without lifecycle policies, every pushed image is retained indefinitely.
# Storage costs accumulate quickly in active CI/CD pipelines. These policies
# enforce two rules per repository:
#
# Rule 1 — expire untagged images after 1 day:
#   Untagged images are typically intermediate build layers or images that
#   were pushed but never tagged. They have no practical use after the build
#   completes and can be safely deleted.
#
# Rule 2 — keep the 10 most recent tagged images:
#   Retaining recent images allows rollback to any of the last 10 builds.
#   Once a repository has more than 10 tagged images the oldest are expired.
#   The tagPrefixList covers images tagged with "v" (e.g. v1.2.3) and "latest".

resource "aws_ecr_lifecycle_policy" "account_service" {
  repository = aws_ecr_repository.account_service.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "transaction_service" {
  repository = aws_ecr_repository.transaction_service.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
