output "vpc_id" {
  value = data.aws_vpcs.default.ids[0]
}

output "subnet_ids" {
  value = data.aws_subnets.default.ids
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.task_tracker.repository_url
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "ci_access_key_id" {
  value       = aws_iam_access_key.ci.id
  description = "Access key ID for CI user"
  sensitive   = true
}

output "ci_secret_access_key" {
  value       = aws_iam_access_key.ci.secret
  description = "Secret access key for CI user"
  sensitive   = true
}

output "ai_gate_lambda_arn" {
  value       = aws_lambda_function.ai_gate.arn
  description = "ARN of the AI gate Lambda function"
}