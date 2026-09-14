# Daily EventBridge rule for the commission/reconciliation job.
#
# DEFERRED: no aws_cloudwatch_event_target is created here. We do not yet
# have a real compute target (Lambda / ECS RunTask / Step Function) for
# this job, and inventing one would mean wiring a fake dependency just to
# satisfy the shape of the architecture. A rule with zero targets is a
# valid, harmless AWS resource — it evaluates on schedule and invokes
# nothing.
#
# Follow-up required before this does anything:
#   Add an `aws_cloudwatch_event_target` (and its invoke IAM role, e.g.
#   via `aws_iam_role` + a rule-specific policy) pointing this rule's
#   name/ARN at whatever executes commission reconciliation once that
#   exists — likely an ECS RunTask target reusing the `commission`
#   service's task definition, or a dedicated Lambda.

resource "aws_cloudwatch_event_rule" "this" {
  name                = "${var.name_prefix}-${var.rule_name}"
  description         = var.description
  schedule_expression = var.schedule_expression
  state               = var.enabled ? "ENABLED" : "DISABLED"

  tags = var.tags
}
