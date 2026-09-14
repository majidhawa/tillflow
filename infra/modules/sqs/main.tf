resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-${var.queue_name}-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

resource "aws_sqs_queue" "this" {
  name                       = "${var.name_prefix}-${var.queue_name}"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = var.tags
}

# Let the DLQ's source be this queue, so console/CLI tooling can trace
# redrive relationships (has no effect on the redrive_policy above).
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this.arn]
  })
}

# Scoped send/receive access for the shared ECS task role. Additive
# only — does not modify the role itself.
data "aws_iam_policy_document" "task_queue_access" {
  statement {
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.this.arn, aws_sqs_queue.dlq.arn]
  }
}

resource "aws_iam_role_policy" "task_queue_access" {
  name   = "${var.name_prefix}-ecs-task-sqs-access"
  role   = var.ecs_task_role_name
  policy = data.aws_iam_policy_document.task_queue_access.json
}
