output "cluster_id" {
  description = "ID of the ECS cluster."
  value       = aws_ecs_cluster.this.id
}

output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "execution_role_arn" {
  description = "ARN of the shared ECS task execution role."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "ARN of the shared ECS task role."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the shared ECS task role, for attaching additional scoped IAM policies from other modules."
  value       = aws_iam_role.task.name
}

output "log_group_names" {
  description = "Map of service name to CloudWatch log group name."
  value       = { for name, lg in aws_cloudwatch_log_group.app : name => lg.name }
}
