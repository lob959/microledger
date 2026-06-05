# =============================================================================
# Networking — VPC, Subnets, Routing, and Security Groups
# =============================================================================
#
# This file establishes the entire network layer. Every other resource in the
# stack depends on something declared here: the VPC, the subnets (public for
# the ALB and NAT Gateway, private for ECS tasks), the internet and NAT
# gateways for inbound/outbound internet access, and the security groups that
# control exactly which traffic is allowed between components.
#
# Network layout (ap-southeast-2, two AZs):
#
#   10.0.0.0/16
#   ├── Public  ap-southeast-2a  10.0.1.0/24   ALB node + NAT Gateway
#   ├── Public  ap-southeast-2b  10.0.2.0/24   ALB node
#   ├── Private ap-southeast-2a  10.0.10.0/24  ECS Fargate tasks
#   └── Private ap-southeast-2b  10.0.11.0/24  ECS Fargate tasks
# =============================================================================

# ---------------------------------------------------------------------------
# Availability Zones
# ---------------------------------------------------------------------------
# AWS organises each region into multiple, physically separate data centres
# called Availability Zones (AZs). Deploying across two AZs means the
# application survives a single-AZ failure. The ALB requires at least two AZs
# — it places load-balancer nodes in each. ECS tasks are distributed across
# both private subnets so a single-AZ outage only removes half of capacity.
# The local value constructs the AZ names from the region variable (e.g.
# "ap-southeast-2a", "ap-southeast-2b") so the code works in any region.

locals {
  azs = ["${var.aws_region}a", "${var.aws_region}b"]
}

# ---------------------------------------------------------------------------
# VPC (Virtual Private Cloud)
# ---------------------------------------------------------------------------
# A VPC is a logically isolated private network inside AWS. Every resource in
# this stack — subnets, ECS tasks, the ALB, the NAT Gateway, and the Cloud
# Map DNS namespace — lives inside this one VPC. Resources in different VPCs
# cannot communicate unless explicitly peered.
#
# enable_dns_support   = true  — allows instances to resolve domain names
#                               via the AWS-provided DNS resolver (169.254.169.253).
#                               Required for ECS tasks to reach DynamoDB, ECR,
#                               CloudWatch, and SSM endpoints.
# enable_dns_hostnames = true  — required for AWS Cloud Map service discovery.
#                               Cloud Map registers each ECS task as an A record;
#                               without DNS hostnames, those records cannot be
#                               resolved from within the VPC, so
#                               "account-service.microledger.local" would not work.

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# Public Subnets
# ---------------------------------------------------------------------------
# Public subnets have a route to the Internet Gateway, which means resources
# placed here can receive inbound traffic from the internet and initiate
# outbound connections directly.
#
# The ALB is placed in these subnets because it needs to accept requests from
# the public internet on port 80. ALB requires at least two subnets in
# different AZs — it places an ALB node in each, providing redundancy.
#
# The NAT Gateway also lives in a public subnet so it can forward outbound
# requests from private subnets out to the internet and return the responses.
#
# map_public_ip_on_launch = true — any EC2 instance or ENI launched in these
# subnets receives a public IP automatically. ECS Fargate tasks are placed in
# private subnets, not here, so this setting only affects the ALB and NAT GW.
#
# CIDR blocks derived dynamically:
#   count.index + 1 → 10.0.1.0/24 (AZ-a) and 10.0.2.0/24 (AZ-b)

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet("10.0.0.0/16", 8, count.index + 1)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-${local.azs[count.index]}"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# Private Subnets
# ---------------------------------------------------------------------------
# Private subnets have no route to the Internet Gateway. Resources here have
# no public IP and cannot receive unsolicited inbound traffic from the internet.
# This is where all ECS Fargate tasks run.
#
# ECS tasks need outbound internet access to pull Docker images from ECR and
# send logs to CloudWatch. That outbound path goes through the NAT Gateway in
# the public subnet — the NAT GW translates the private source IP to its own
# public IP, making the connection appear to originate from the NAT GW.
#
# CIDR blocks:
#   count.index + 10 → 10.0.10.0/24 (AZ-a) and 10.0.11.0/24 (AZ-b)

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-${local.azs[count.index]}"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# Internet Gateway
# ---------------------------------------------------------------------------
# The Internet Gateway is a horizontally scaled, redundant VPC component that
# allows resources in public subnets to communicate with the internet. It
# handles both inbound traffic (e.g. HTTP requests to the ALB) and outbound
# traffic (e.g. the ALB fetching health checks, the NAT GW forwarding requests
# from private subnets).
#
# A VPC can have only one IGW attached at a time. It is attached to the VPC
# here and referenced by the public route table below.

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# Elastic IP for NAT Gateway
# ---------------------------------------------------------------------------
# The NAT Gateway requires a static public IPv4 address (an Elastic IP). ECS
# tasks making outbound connections through the NAT GW appear to the internet
# as this IP address. This is useful if external services need to allowlist the
# outbound IP of your application.
#
# domain = "vpc" — the modern way to allocate an EIP for VPC use (the older
# "standard" domain is for EC2-Classic, which no longer exists).

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-${var.environment}-nat-eip"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# NAT Gateway
# ---------------------------------------------------------------------------
# A NAT (Network Address Translation) Gateway allows resources in private
# subnets to initiate outbound connections to the internet, while remaining
# unreachable from the internet for inbound connections. ECS Fargate tasks
# use it to pull images from ECR, send logs to CloudWatch Logs, and read
# parameters from SSM — all of which are AWS-public endpoints.
#
# The NAT GW is placed in the first public subnet (AZ-a). A single NAT GW is
# a cost trade-off: each gateway costs ~$32 AUD/month plus data transfer. For
# production HA, add a second NAT GW in AZ-b with its own route table so
# private tasks in AZ-b do not lose outbound connectivity if AZ-a goes down.
#
# depends_on = [aws_internet_gateway.main] — the NAT GW cannot become active
# until the IGW is attached, because the NAT GW's own outbound traffic uses
# the IGW route. Terraform may not infer this dependency automatically.

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project}-${var.environment}-nat"
    Service = "shared"
  }

  depends_on = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------------------
# Public Route Table
# ---------------------------------------------------------------------------
# A route table is a set of rules that determine where network traffic is
# directed. This table is associated with the public subnets and contains a
# default route (0.0.0.0/0) pointing to the Internet Gateway, which is what
# makes the subnets "public" — any traffic not destined for the VPC CIDR
# is forwarded out to the internet via the IGW.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-public-rt"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# Private Route Table
# ---------------------------------------------------------------------------
# The private route table is associated with the private subnets. Its default
# route (0.0.0.0/0) points to the NAT Gateway rather than the IGW. This means
# ECS tasks can initiate outbound connections (to ECR, CloudWatch, etc.) but
# cannot be directly reached from the internet — no unsolicited inbound traffic
# can reach a resource in a private subnet through the NAT GW.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-private-rt"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# Route Table Associations
# ---------------------------------------------------------------------------
# Route tables are not applied to subnets automatically — each subnet must be
# explicitly associated with the route table that should govern its traffic.
# Without these associations, subnets fall back to the VPC's default route
# table, which only routes within the VPC CIDR and provides no internet access.

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# ALB Security Group
# ---------------------------------------------------------------------------
# A security group acts as a virtual firewall for a network interface. This
# security group is attached to the Application Load Balancer and defines
# what traffic the ALB will accept and send.
#
# Inbound rule — TCP 80 from 0.0.0.0/0:
#   Allows HTTP requests from any IP on the internet to reach the ALB.
#   In a production environment you would also add port 443 and attach an
#   ACM TLS certificate to terminate HTTPS at the ALB.
#
# Outbound rule — all traffic:
#   The ALB needs to forward requests to ECS task private IPs on port 8000
#   and also perform health checks. The broad outbound rule covers both.
#   It is possible to restrict this to the ecs_sg only, but it adds complexity
#   without a security benefit when the VPC already isolates the workload.

resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-alb-sg"
  description = "Allow inbound HTTP from the internet to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-${var.environment}-alb-sg"
    Service = "shared"
  }
}

# ---------------------------------------------------------------------------
# ECS Security Group
# ---------------------------------------------------------------------------
# This security group is attached to every ECS Fargate task ENI (the private
# network interface each task gets in awsvpc mode). It restricts inbound
# traffic to exactly two sources:
#
# Rule 1 — port 8000 from alb_sg:
#   Allows the ALB to forward HTTP requests to the transaction-service tasks.
#   Using a security group reference (rather than a CIDR) means only traffic
#   from resources with the ALB security group is allowed — not the entire
#   internet or even the full VPC CIDR.
#
# Rule 2 — port 8000 from self:
#   Allows ECS tasks to call each other. The transaction-service calls the
#   account-service's internal balance endpoint on port 8000. Both services
#   share this security group, so "self" reference permits intra-service
#   communication without opening access to anything else in the VPC.
#
# Outbound — all traffic:
#   Tasks must reach ECR (image pulls), CloudWatch Logs (structured logging),
#   SSM Parameter Store (config injection), and DynamoDB (data access). All
#   of these are AWS-public endpoints reached via the NAT Gateway.

resource "aws_security_group" "ecs" {
  name        = "${var.project}-${var.environment}-ecs-sg"
  description = "Allow traffic from ALB and between ECS services"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "From ALB to transaction-service"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Inter-service: transaction-service to account-service"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-${var.environment}-ecs-sg"
    Service = "shared"
  }
}
