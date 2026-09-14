# --- Network (existing, unchanged) ---

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (ECS tasks)."
  value       = module.network.private_subnet_ids
}

# --- ECS ---

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs_cluster.cluster_name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN."
  value       = module.ecs_cluster.cluster_arn
}

# --- ECR ---

output "ecr_repository_urls" {
  description = "Map of service name to ECR repository URL."
  value       = module.ecr.repository_urls
}

# --- ALB / API Gateway VPC Link preparation ---

output "alb_arn" {
  description = "ALB ARN."
  value       = module.alb.alb_arn
}

output "alb_dns_name" {
  description = "ALB public DNS name."
  value       = module.alb.alb_dns_name
}

output "alb_listener_arn" {
  description = "ALB HTTP listener ARN — the integration target for an API Gateway HTTP API VPC Link."
  value       = module.alb.listener_arn
}

output "alb_target_group_arns" {
  description = "Map of service name to ALB target group ARN."
  value       = module.alb.target_group_arns
}

output "alb_security_group_id" {
  description = "Security group ID attached to the ALB."
  value       = module.alb.alb_security_group_id
}

output "ecs_tasks_security_group_id" {
  description = "Security group ID for ECS tasks (ingress restricted to the ALB security group only)."
  value       = module.alb.ecs_tasks_security_group_id
}

# --- RDS PostgreSQL ---

output "rds_endpoint" {
  description = "RDS instance endpoint (host:port)."
  value       = module.rds_postgres.db_endpoint
}

output "rds_port" {
  description = "RDS instance port."
  value       = module.rds_postgres.db_port
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN holding the generated master credentials + connection info. The password itself is never output."
  value       = module.rds_postgres.db_secret_arn
}

output "rds_subnet_group_id" {
  description = "RDS DB subnet group ID."
  value       = module.rds_postgres.db_subnet_group_id
}

output "rds_security_group_id" {
  description = "Security group ID attached to the RDS instance."
  value       = module.rds_postgres.db_security_group_id
}

# --- Redis / Valkey ---

output "redis_endpoint" {
  description = "Primary endpoint hostname for the cache."
  value       = module.redis.primary_endpoint_address
}

output "redis_port" {
  description = "Cache port."
  value       = module.redis.port
}

output "redis_security_group_id" {
  description = "Security group ID attached to the cache."
  value       = module.redis.security_group_id
}

# --- SQS ---

output "sqs_queue_url" {
  description = "URL of the primary payment/event queue."
  value       = module.sqs.queue_url
}

output "sqs_queue_arn" {
  description = "ARN of the primary payment/event queue."
  value       = module.sqs.queue_arn
}

output "sqs_dlq_url" {
  description = "URL of the dead-letter queue."
  value       = module.sqs.dlq_url
}

output "sqs_dlq_arn" {
  description = "ARN of the dead-letter queue."
  value       = module.sqs.dlq_arn
}

# --- S3 ---

output "s3_bucket_names" {
  description = "Map of purpose to bucket name."
  value       = module.s3_buckets.bucket_names
}

output "s3_bucket_arns" {
  description = "Map of purpose to bucket ARN."
  value       = module.s3_buckets.bucket_arns
}

# --- EventBridge ---

output "commission_schedule_rule_arn" {
  description = "ARN of the daily commission/reconciliation schedule rule. No target is wired yet."
  value       = module.commission_schedule.rule_arn
}

output "commission_schedule_rule_name" {
  description = "Name of the daily commission/reconciliation schedule rule."
  value       = module.commission_schedule.rule_name
}

# --- Secrets placeholders ---

output "app_secret_arns" {
  description = "Map of secret key to Secrets Manager ARN. No secret values are exposed by this output."
  value       = module.app_secrets.secret_arns
}

# --- API Gateway / VPC Link ---

output "api_gateway_id" {
  description = "ID of the HTTP API."
  value       = module.apigw.api_id
}

output "api_gateway_endpoint" {
  description = "Invoke URL for the HTTP API's default (auto-deployed) stage."
  value       = module.apigw.api_endpoint
}

output "api_gateway_vpc_link_id" {
  description = "ID of the API Gateway VPC Link."
  value       = module.apigw.vpc_link_id
}
