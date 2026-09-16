output "canary_name" {
  description = "Name of the Synthetics canary."
  value       = aws_synthetics_canary.this.name
}

output "canary_artifacts_bucket" {
  description = "S3 bucket storing canary run artifacts (screenshots, HAR files, logs)."
  value       = aws_s3_bucket.canary_artifacts.id
}
