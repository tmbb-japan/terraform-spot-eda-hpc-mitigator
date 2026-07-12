# main.tf

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 프로덕션에서는 S3 + DynamoDB 원격 백엔드 활성화
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "eda-hpc/terraform.tfstate"
  #   region         = "ap-northeast-2"
  #   dynamodb_table = "terraform-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ==============================================================================
# Locals: 일관된 네이밍 및 공통 값 관리
# ==============================================================================
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ==============================================================================
# 1. 네트워크 인프라 (VPC, Subnet, IGW, Route Table)
# ==============================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1) # 10.0.1.0/24
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = { Name = "${local.name_prefix}-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ==============================================================================
# 2. 보안 그룹 (Security Groups)
# ==============================================================================
resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-worker-sg"
  description = "EDA Spot Worker - Egress only, SSH restricted"
  vpc_id      = aws_vpc.main.id

  # SSH: allowed_ssh_cidrs가 비어있으면 규칙 자체를 생성하지 않음
  dynamic "ingress" {
    for_each = length(var.allowed_ssh_cidrs) > 0 ? [1] : []
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_ssh_cidrs
      description = "SSH from allowed CIDRs"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "${local.name_prefix}-worker-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "efs" {
  name        = "${local.name_prefix}-efs-sg"
  description = "EFS - Allow NFS inbound from worker SG only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
    description     = "NFS from worker instances"
  }

  tags = { Name = "${local.name_prefix}-efs-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# ==============================================================================
# 3. IAM Role & Instance Profile (EC2에 필요한 최소 권한 부여)
# ==============================================================================
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "worker" {
  name               = "${local.name_prefix}-worker-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = { Name = "${local.name_prefix}-worker-role" }
}

# EFS 마운트 + CloudWatch Logs 전송에 필요한 최소 정책
data "aws_iam_policy_document" "worker_permissions" {
  statement {
    sid = "EFSAccess"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:DescribeMountTargets",
    ]
    resources = [aws_efs_file_system.shared_storage.arn]
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.agent.arn}:*"]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "${local.name_prefix}-worker-policy"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker_permissions.json
}

resource "aws_iam_instance_profile" "worker" {
  name = "${local.name_prefix}-worker-profile"
  role = aws_iam_role.worker.name
}

# ==============================================================================
# 4. 스토리지 (EFS)
# ==============================================================================
resource "aws_efs_file_system" "shared_storage" {
  creation_token = "${local.name_prefix}-efs"
  encrypted      = true

  throughput_mode = "bursting"

  tags = { Name = "${local.name_prefix}-efs" }
}

resource "aws_efs_mount_target" "main" {
  file_system_id  = aws_efs_file_system.shared_storage.id
  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.efs.id]
}

# ==============================================================================
# 5. 모니터링 (CloudWatch Log Group)
# ==============================================================================
resource "aws_cloudwatch_log_group" "agent" {
  name              = "/eda-hpc/${var.environment}/spot-agent"
  retention_in_days = 14
  tags              = { Name = "${local.name_prefix}-agent-logs" }
}

# ==============================================================================
# 6. 컴퓨팅 (EC2 Spot Instance)
# ==============================================================================
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_spot_instance_request" "worker" {
  ami                  = data.aws_ami.amazon_linux.id
  instance_type        = var.instance_type
  spot_type            = "one-time"
  wait_for_fulfillment = true
  spot_price           = var.spot_max_price != "" ? var.spot_max_price : null

  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.worker.name
  key_name                    = var.key_pair_name != "" ? var.key_pair_name : null
  associate_public_ip_address = true

  # IMDSv2 강제 적용 (보안 필수)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/scripts/user_data.sh", {
    efs_id          = aws_efs_file_system.shared_storage.id
    log_group       = aws_cloudwatch_log_group.agent.name
    project_name    = var.project_name
    simulate_script     = file("${path.module}/scripts/simulate.sh")
    agent_script        = file("${path.module}/scripts/agent.py")
    manual_drain_script = file("${path.module}/scripts/manual_drain.sh")
  }))

  tags = { Name = "${local.name_prefix}-spot-worker" }

  depends_on = [aws_efs_mount_target.main]
}