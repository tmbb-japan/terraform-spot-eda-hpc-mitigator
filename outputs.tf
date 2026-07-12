output "vpc_id" {
  description = "생성된 VPC ID"
  value       = aws_vpc.main.id
}

output "asg_name" {
  description = "Auto Scaling Group 이름 (스팟 자동 복구)"
  value       = aws_autoscaling_group.worker.name
}

output "launch_template_id" {
  description = "Launch Template ID"
  value       = aws_launch_template.worker.id
}

output "efs_id" {
  description = "공유 스토리지 EFS 파일 시스템 ID"
  value       = aws_efs_file_system.shared_storage.id
}

output "efs_dns_name" {
  description = "EFS DNS 이름 (수동 마운트 시 사용)"
  value       = aws_efs_file_system.shared_storage.dns_name
}

output "cloudwatch_log_group" {
  description = "에이전트 로그가 전송되는 CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.agent.name
}

output "subnet_azs" {
  description = "서브넷이 배포된 가용 영역 목록"
  value       = aws_subnet.public[*].availability_zone
}

output "worker_iam_role_arn" {
  description = "워커 인스턴스에 부여된 IAM Role ARN"
  value       = aws_iam_role.worker.arn
}
