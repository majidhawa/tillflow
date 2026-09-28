# Bootstrap: creates the S3 bucket + DynamoDB table used as the
# Terraform backend for all other infra/ configurations.
# This state itself is local until the backend exists (chicken-and-egg
# bootstrap problem), so this module intentionally has no backend block.

provider "aws" {
  region = var.region
}

# Random suffix keeps the state bucket name globally unique without
# hardcoding an AWS account ID into the config.
resource "random_id" "state_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.name_prefix}-terraform-state-${random_id.state_suffix.hex}"

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Customer-managed key so state encryption isn't tied to the account-wide
# AWS-managed S3 key — this bucket is applied manually (outside the CI
# OIDC roles), so the key needs no cross-module IAM plumbing.
resource "aws_kms_key" "terraform_state" {
  description         = "CMK for the ${var.name_prefix} Terraform state bucket"
  enable_key_rotation = true

  tags = var.tags
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/${var.name_prefix}-terraform-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "${var.name_prefix}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = var.tags
}
