output "db_endpoint" {
  description = "RDS instance endpoint (host:port)."
  value       = aws_db_instance.this.endpoint
}

output "db_address" {
  description = "RDS instance hostname."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "RDS instance port."
  value       = aws_db_instance.this.port
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the generated master credentials + connection info. The password itself is never output."
  value       = aws_secretsmanager_secret.db.arn
}

output "db_subnet_group_id" {
  description = "DB subnet group name/ID."
  value       = aws_db_subnet_group.this.id
}

output "db_security_group_id" {
  description = "Security group ID attached to the RDS instance."
  value       = aws_security_group.rds.id
}
