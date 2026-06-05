# =============================================================================
# ALB — Application Load Balancer
# =============================================================================
#
# The Application Load Balancer is the single public entry point into the
# Microledger stack. It accepts HTTP traffic from the internet on port 80 and
# forwards it to the transaction-service ECS tasks in the private subnets.
#
# The account-service is NOT attached to this ALB. It is only reachable from
# within the VPC via the Cloud Map private DNS name
# "account-service.microledger.local". This enforces the architectural boundary:
# the transaction-service is the public API; the account-service is internal
# infrastructure. In particular, the balance-update endpoint
# (PUT /accounts/{id}/balance) is never directly reachable from the internet.
#
# Traffic flow:
#   Client → ALB (port 80, public subnet) → target group → ECS task (port 8000, private subnet)
# =============================================================================

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
# An ALB operates at OSI Layer 7 (HTTP/HTTPS). It can route requests based on
# path, hostname, headers, or HTTP method — useful if you later want to expose
# both services on the same ALB using path-based rules.
#
# internal = false — the ALB receives a public DNS name and routes from the
# internet. An internal ALB would only be reachable from within the VPC, which
# is appropriate for service-to-service load balancing. This ALB is the public
# entry point so it must be internet-facing.
#
# subnets = aws_subnet.public[*].id — the ALB is placed in the two public
# subnets so it can receive inbound traffic through the Internet Gateway. The
# ALB nodes themselves do not run in the private subnets — only the ECS tasks do.
#
# security_groups = [aws_security_group.alb.id] — the ALB SG allows port 80
# from 0.0.0.0/0 and permits outbound traffic to the ECS tasks.

resource "aws_lb" "main" {
  name               = "${var.project}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${var.project}-${var.environment}-alb"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# Target Group — transaction-service
# ---------------------------------------------------------------------------
# A target group is a pool of destinations (targets) that the ALB forwards
# requests to. For Fargate tasks in awsvpc network mode, each task gets its
# own private IP and ENI. The ECS service automatically registers and
# deregisters task IPs with this group as tasks start and stop.
#
# target_type = "ip" — required for Fargate awsvpc mode. The alternative,
# "instance", is for EC2 tasks and would not work here because Fargate tasks
# do not have an EC2 instance ID.
#
# port = 8000 — the port the transaction-service container listens on. This
# is the same port set in the Dockerfile CMD and in the portMappings of the
# task definition in ecs.tf.
#
# Health check:
#   path = "/health" — the FastAPI endpoint that returns {"status":"ok"}.
#   The ALB sends a GET /health request to each task every 30 seconds. A task
#   must return HTTP 200 twice before the ALB routes traffic to it (healthy
#   threshold = 2), and must fail 3 consecutive checks before the ALB removes
#   it (unhealthy threshold = 3). This gives ECS time to recover a flapping
#   task before it is taken out of rotation.

resource "aws_lb_target_group" "transaction_service" {
  name        = "${var.project}-${var.environment}-tx-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name = "${var.project}-${var.environment}-tx-tg"
    Service = "transaction-service"
  }
}

# ---------------------------------------------------------------------------
# ALB Listener — HTTP port 80
# ---------------------------------------------------------------------------
# A listener is a process that checks for incoming connection requests to the
# ALB on a specified port and protocol. This listener accepts all HTTP traffic
# on port 80 and forwards it to the transaction-service target group by default.
#
# In a production environment you would:
#   1. Add a second listener on port 443 with an ACM TLS certificate to serve
#      HTTPS, and redirect HTTP (port 80) to HTTPS.
#   2. Optionally add listener rules to route specific paths (e.g. /accounts/*)
#      to the account-service target group if you want to expose account CRUD
#      through the same ALB.
#
# The ECS service for transaction-service (ecs.tf) declares
# depends_on = [aws_lb_listener.http] to ensure the listener exists before
# ECS registers the tasks with the target group.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.transaction_service.arn
  }
  tags = {
    Name    = "${var.project}-${var.environment}-http-listener"
    Service = "shared"
  }
}
