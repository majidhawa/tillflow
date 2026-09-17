# SNS -> Lambda -> Slack incoming webhook. CloudWatch Alarms publish to
# the SNS topic this module creates; the Lambda reads the webhook URL
# from Secrets Manager at invocation time (never from Terraform state or
# an env var literal) and posts a formatted message. See
# lambda/handler.py for how the alert-contract fields are extracted.

data "aws_caller_identity" "current" {}

# Customer-managed key, not the AWS-managed alias/aws/sns default — this
# key's policy explicitly grants the CloudWatch Alarms service principal
# publish-time encrypt/decrypt (the standard AWS-documented pattern for
# an encrypted SNS topic that CloudWatch Alarms publishes to), plus root
# account access. The Lambda subscriber's own kms:Decrypt grant is on its
# execution role, below.
data "aws_iam_policy_document" "alerts_key" {
  statement {
    sid       = "EnableRootAccountFullAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudWatchAlarmsToPublish"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "alerts" {
  description         = "CMK for ${var.name_prefix} Slack alert SNS topic"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.alerts_key.json

  tags = var.tags
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/${var.name_prefix}-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"

  kms_master_key_id = aws_kms_key.alerts.arn

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "slack_notifier" {
  name              = "/aws/lambda/${var.name_prefix}-slack-notifier"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_iam_role" "slack_notifier" {
  name = "${var.name_prefix}-slack-notifier"

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

data "aws_iam_policy_document" "slack_notifier" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.slack_notifier.arn}:*"]
  }

  statement {
    sid       = "ReadSlackWebhookSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.slack_webhook_secret_arn]
  }

  statement {
    sid       = "DecryptSnsMessages"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.alerts.arn]
  }
}

resource "aws_iam_role_policy" "slack_notifier" {
  name   = "${var.name_prefix}-slack-notifier-permissions"
  role   = aws_iam_role.slack_notifier.id
  policy = data.aws_iam_policy_document.slack_notifier.json
}

data "archive_file" "slack_notifier" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/.build/slack-notifier.zip"
}

resource "aws_lambda_function" "slack_notifier" {
  function_name = "${var.name_prefix}-slack-notifier"
  role          = aws_iam_role.slack_notifier.arn

  filename         = data.archive_file.slack_notifier.output_path
  source_code_hash = data.archive_file.slack_notifier.output_base64sha256

  handler = "handler.lambda_handler"
  runtime = "python3.12"
  timeout = 10

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET_ARN = var.slack_webhook_secret_arn
      ENVIRONMENT_NAME         = var.environment_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.slack_notifier]

  tags = var.tags
}

resource "aws_sns_topic_subscription" "slack_notifier" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier.arn
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSnsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}
