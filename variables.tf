# ==========================================
# 1. AWS 리전 설정 (서울 리전 기본 고정)
# ==========================================
variable "aws_region" {
  description = "인프라가 배포될 AWS 리전 주소"
  type        = string
  default     = "ap-northeast-2"
}

# ==========================================
# 2. 스팟 인스턴스 사양 설정
# ==========================================
variable "instance_type" {
  description = "시뮬레이션을 돌릴 EC2 스팟 인스턴스의 스펙"
  type        = string
  default     = "c5.large"
}

# ==========================================
# 3. 프로젝트 네이밍 태그 (선택)
# ==========================================
variable "project_name" {
  description = "모든 리소스 이름 뒤에 붙을 프로젝트 접두사"
  type        = string
  default     = "spot-eda-hpc"
}