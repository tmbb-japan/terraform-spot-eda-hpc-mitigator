variable "aws_region" {
  description = "인프라가 배포될 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "EC2 스팟 인스턴스 타입 (컴퓨팅 최적화 권장)"
  type        = string
  default     = "c5.large"
}

variable "project_name" {
  description = "모든 리소스의 Name 태그 접두사"
  type        = string
  default     = "eda-hpc"
}

variable "environment" {
  description = "배포 환경 식별자 (dev / staging / prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment는 dev, staging, prod 중 하나여야 합니다."
  }
}

variable "allowed_ssh_cidrs" {
  description = "SSH 접근을 허용할 CIDR 블록 목록 (보안을 위해 최소 범위 지정)"
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
  default     = "10.0.0.0/16"
}

variable "spot_max_price" {
  description = "스팟 인스턴스 최대 입찰가 (빈 문자열이면 온디맨드 가격 사용)"
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 SSH 접속에 사용할 Key Pair 이름 (빈 문자열이면 SSH 비활성)"
  type        = string
  default     = ""
}