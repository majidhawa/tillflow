output "task_definition_arn" {
  description = "ARN of the registered task definition (always created)."
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  description = "Family name of the task definition."
  value       = aws_ecs_task_definition.this.family
}

output "service_name" {
  description = "Name of the ECS service, if enabled (null otherwise)."
  value       = var.enable_service ? aws_ecs_service.this[0].name : null
}
