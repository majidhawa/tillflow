output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state. Used to fill in environments/*/backend.tf."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the S3 state bucket."
  value       = aws_s3_bucket.terraform_state.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB table used for state locking. Used to fill in environments/*/backend.tf."
  value       = aws_dynamodb_table.terraform_locks.name
}
