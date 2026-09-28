output "alb_arn" {
  description = "ARN of the ALB."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Route53 hosted zone ID for the ALB (for alias records)."
  value       = aws_lb.this.zone_id
}

output "listener_arn" {
  description = "ARN of the HTTP listener. This is the integration target for API Gateway VPC Link."
  value       = aws_lb_listener.http.arn
}

output "target_group_arns" {
  description = "Map of service name to target group ARN."
  value       = { for name, tg in aws_lb_target_group.this : name => tg.arn }
}

output "alb_security_group_id" {
  description = "Security group ID attached to the ALB."
  value       = aws_security_group.alb.id
}

output "ecs_tasks_security_group_id" {
  description = "Security group ID for ECS tasks (ingress restricted to the ALB security group only)."
  value       = aws_security_group.ecs_tasks.id
}
