output "primary_endpoint_address" {
  description = "Primary endpoint hostname for the cache."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  description = "Cache port."
  value       = aws_elasticache_replication_group.this.port
}

output "security_group_id" {
  description = "Security group ID attached to the cache."
  value       = aws_security_group.redis.id
}
