# Secret containers only — deliberately no aws_secretsmanager_secret_version
# resources here. Populate real values out-of-band (console, CLI, or a
# separate non-committed process) after apply.

resource "aws_secretsmanager_secret" "this" {
  for_each = { for s in var.secrets : s.key => s }

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.description

  tags = var.tags
}

# Scoped read access for the shared ECS task role. Additive only — does
# not modify the role itself.
#
# CAVEAT: all four app services currently share one ECS task role (see
# infra/modules/ecs-cluster). Granting read access here means every
# service's tasks can technically read these secrets, including Daraja
# config — even though the sale-payment contract states POS must never
# call Daraja directly and only Payments owns provider integration. This
# is an IAM-level gap relative to that contract; tightening it requires
# splitting the shared task role into per-service roles, which is out of
# scope for this batch.
data "aws_iam_policy_document" "task_read_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for s in aws_secretsmanager_secret.this : s.arn]
  }
}

resource "aws_iam_role_policy" "task_read_secrets" {
  name   = "${var.name_prefix}-ecs-task-read-app-secrets"
  role   = var.ecs_task_role_name
  policy = data.aws_iam_policy_document.task_read_secrets.json
}
