output "secret_arns" {
  description = "Map of secret key to Secrets Manager ARN. No secret values are exposed by this module."
  value       = { for name, s in aws_secretsmanager_secret.this : name => s.arn }
}
