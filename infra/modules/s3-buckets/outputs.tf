output "bucket_names" {
  description = "Map of purpose to bucket name."
  value       = { for name, b in aws_s3_bucket.this : name => b.bucket }
}

output "bucket_arns" {
  description = "Map of purpose to bucket ARN."
  value       = { for name, b in aws_s3_bucket.this : name => b.arn }
}
