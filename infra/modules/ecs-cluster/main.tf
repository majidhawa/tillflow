# Shared ECS Fargate cluster, execution/task IAM roles, and per-service
# log groups. Task definitions and services are created per-app by the
# ecs-service module, which references the outputs of this module.

resource "aws_ecs_cluster" "this" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by the ECS agent to pull images from ECR and ship
# container logs to CloudWatch. Not used by application code at runtime.
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: assumed by application/ADOT containers at runtime. Scoped to
# what the ADOT sidecar needs to export traces/metrics/logs.
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "task_observability" {
  statement {
    sid = "OtelExport"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "cloudwatch:PutMetricData",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_observability" {
  name   = "${var.name_prefix}-ecs-task-observability"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_observability.json
}

resource "aws_cloudwatch_log_group" "app" {
  for_each = toset(var.service_names)

  name              = "/ecs/${var.name_prefix}-${each.key}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}
