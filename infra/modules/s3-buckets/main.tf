# One private, versioned, encrypted bucket per purpose. No website
# hosting, no public access of any kind.

resource "random_id" "suffix" {
  for_each = toset(var.purposes)

  byte_length = 4
}

resource "aws_s3_bucket" "this" {
  for_each = toset(var.purposes)

  bucket = "${var.name_prefix}-${each.key}-${random_id.suffix[each.key].hex}"

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-${each.key}"
    Purpose = each.key
  })
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Scoped read/write access for the shared ECS task role. Additive only —
# does not modify the role itself.
data "aws_iam_policy_document" "task_bucket_access" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [for b in aws_s3_bucket.this : "${b.arn}/*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [for b in aws_s3_bucket.this : b.arn]
  }
}

resource "aws_iam_role_policy" "task_bucket_access" {
  name   = "${var.name_prefix}-ecs-task-s3-access"
  role   = var.ecs_task_role_name
  policy = data.aws_iam_policy_document.task_bucket_access.json
}
