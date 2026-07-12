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
data "aws_availability_zones" "available" {
  state = "available"
}

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
  count = min(length(data.aws_availability_zones.available.names), 3)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${local.name_prefix}-public-${data.aws_availability_zones.available.names[count.index]}" }
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
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
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
  count = length(aws_subnet.public)

  file_system_id  = aws_efs_file_system.shared_storage.id
  subnet_id       = aws_subnet.public[count.index].id
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
# 6. 컴퓨팅 (Launch Template + Auto Scaling Group)
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

resource "aws_launch_template" "worker" {
  name_prefix   = "${local.name_prefix}-worker-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  key_name      = var.key_pair_name != "" ? var.key_pair_name : null

  iam_instance_profile {
    name = aws_iam_instance_profile.worker.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2.id]
  }

  # IMDSv2 강제 적용 (보안 필수)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # 스팟 인스턴스 설정
  instance_market_options {
    market_type = "spot"

    spot_options {
      max_price                      = var.spot_max_price != "" ? var.spot_max_price : null
      instance_interruption_behavior = "terminate"
    }
  }

  user_data = base64encode(templatefile("${path.module}/scripts/user_data.sh", {
    efs_id              = aws_efs_file_system.shared_storage.id
    log_group           = aws_cloudwatch_log_group.agent.name
    project_name        = var.project_name
    simulate_script     = file("${path.module}/scripts/simulate.sh")
    agent_script        = file("${path.module}/scripts/agent.py")
    manual_drain_script = file("${path.module}/scripts/manual_drain.sh")
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name_prefix}-spot-worker" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "worker" {
  name                = "${local.name_prefix}-worker-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = aws_subnet.public[*].id

  # 회수 후 새 인스턴스를 빠르게 기동
  health_check_type         = "EC2"
  health_check_grace_period = 120
  default_cooldown          = 30

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  # capacity rebalancing: 회수 전 대체 인스턴스를 미리 준비
  capacity_rebalance = true

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-spot-worker"
    propagate_at_launch = true
  }

  depends_on = [aws_efs_mount_target.main]
}