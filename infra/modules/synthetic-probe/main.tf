# CloudWatch Synthetics canary: an external, one-minute heartbeat against
# the API Gateway edge (or whatever target_url is), independent of
# anything running inside the VPC. This is provisioned ahead of any
# service existing — it will show failing runs until a real backend is
# deployed behind API Gateway, which is expected, not a bug.

resource "random_id" "canary_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "canary_artifacts" {
  bucket = "${var.name_prefix}-canary-artifacts-${random_id.canary_bucket_suffix.hex}"

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-canary-artifacts"
    Purpose = "synthetics-canary-artifacts"
  })
}

resource "aws_s3_bucket_versioning" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Unlike an ALB access-log destination bucket, Synthetics canary
# artifacts fully support SSE-KMS (the canary's own execution role just
# needs kms:GenerateDataKey/kms:Decrypt on the key — granted below).
resource "aws_kms_key" "canary_artifacts" {
  description         = "CMK for ${var.name_prefix} Synthetics canary artifacts"
  enable_key_rotation = true

  tags = var.tags
}

resource "aws_kms_alias" "canary_artifacts" {
  name          = "alias/${var.name_prefix}-canary-artifacts"
  target_key_id = aws_kms_key.canary_artifacts.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.canary_artifacts.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  rule {
    id     = "expire-canary-artifacts"
    status = "Enabled"
    filter {}

    expiration {
      days = var.artifact_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.artifact_expiration_days
    }
  }
}

resource "aws_iam_role" "canary" {
  name = "${var.name_prefix}-synthetics-canary"

  # Synthetics canaries execute as Lambda functions under the hood.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

data "aws_iam_policy_document" "canary" {
  statement {
    sid       = "WriteArtifacts"
    actions   = ["s3:PutObject", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.canary_artifacts.arn, "${aws_s3_bucket.canary_artifacts.arn}/*"]
  }

  statement {
    sid       = "WriteArtifactsKms"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.canary_artifacts.arn]
  }

  # Required by the Synthetics library itself (documented minimal canary
  # execution role); no per-bucket ARN form exists for this action.
  statement {
    sid       = "ListAllBuckets"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  # Synthetics auto-creates a "cwsyn-<canary-name>-*" log group at first
  # run; Terraform never creates or manages it, but the canary's own
  # execution role needs to write to it.
  statement {
    sid = "CanaryLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/aws/lambda/cwsyn-${var.name_prefix}-*"]
  }

  statement {
    sid       = "CanaryMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CloudWatchSynthetics"]
    }
  }
}

resource "aws_iam_role_policy" "canary" {
  name   = "${var.name_prefix}-synthetics-canary-permissions"
  role   = aws_iam_role.canary.id
  policy = data.aws_iam_policy_document.canary.json
}

# AWS Synthetics requires this exact folder layout inside the zip for an
# inline (non-S3) canary script: nodejs/node_modules/<file>.js.
data "archive_file" "canary_script" {
  type        = "zip"
  source_dir  = "${path.module}/canary"
  output_path = "${path.module}/.build/heartbeat.zip"
}

resource "aws_synthetics_canary" "this" {
  name                 = "${var.name_prefix}-probe"
  artifact_s3_location = "s3://${aws_s3_bucket.canary_artifacts.bucket}/canary/"
  execution_role_arn   = aws_iam_role.canary.arn
  runtime_version      = var.runtime_version
  handler              = "heartbeat.handler"

  zip_file = data.archive_file.canary_script.output_path

  schedule {
    expression = var.schedule_expression
  }

  run_config {
    timeout_in_seconds = 30
    environment_variables = {
      TARGET_URL = var.target_url
    }
  }

  start_canary = true

  tags = var.tags
}
