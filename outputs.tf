output "vpc_id" {
  description = "생성된 VPC ID"
  value       = aws_vpc.main.id
}

output "spot_instance_id" {
  description = "스팟 인스턴스 요청에 의해 할당된 인스턴스 ID"
  value       = aws_spot_instance_request.worker.spot_instance_id
}

output "spot_instance_public_ip" {
  description = "스팟 인스턴스의 퍼블릭 IP (SSH 접속용)"
  value       = aws_spot_instance_request.worker.public_ip
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

output "worker_iam_role_arn" {
  description = "워커 인스턴스에 부여된 IAM Role ARN"
  value       = aws_iam_role.worker.arn
}
