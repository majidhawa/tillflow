# ALB + its security group, plus the ECS task security group that only
# trusts traffic originating from the ALB (no direct internet ingress to
# ECS tasks). Backend services are reached by ALB listener rules based on
# path prefix.
#
# This module intentionally creates NO ingress rule on the ALB security
# group. The only permitted ingress (from the API Gateway VPC Link
# security group) is wired in infra/environments/dev/main.tf, since that
# rule needs both this module's and the apigw-vpclink module's outputs —
# putting it in either module would create a circular module dependency.

locals {
  services_by_name = { for s in var.services : s.name => s }
  web_service      = var.services[0]
  backend_services = slice(var.services, 1, length(var.services))
  # Deterministic, stable listener rule priorities for the non-default services.
  backend_priorities = { for idx, s in local.backend_services : s.name => 10 + idx }
  # Multiple services can share the same container port (they currently all
  # use 8080). Dedupe so we register exactly one ingress rule per distinct
  # port instead of one identical rule per service, which AWS rejects as
  # InvalidPermission.Duplicate.
  ecs_ingress_ports = toset([for s in var.services : tostring(s.container_port)])
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Public ALB ingress on ${var.listener_port}/tcp"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-alb-sg"
  })
}

# Scoped to exactly what the ALB forwards to: the ECS tasks security
# group, on the container ports it has target groups for. Not 0.0.0.0/0 —
# the ALB never needs to reach anything outside the VPC.
resource "aws_security_group_rule" "alb_egress_to_ecs" {
  for_each = local.ecs_ingress_ports

  type                     = "egress"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.ecs_tasks.id
  from_port                = tonumber(each.value)
  to_port                  = tonumber(each.value)
  protocol                 = "tcp"
  description              = "ALB to container port ${each.value}"
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-ecs-tasks-sg"
  description = "ECS tasks: ingress only from the ALB security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ecs-tasks-sg"
  })
}

# One ingress rule per distinct container port, sourced strictly from the
# ALB security group — never a CIDR block.
resource "aws_security_group_rule" "ecs_ingress_from_alb" {
  for_each = local.ecs_ingress_ports

  type                     = "ingress"
  security_group_id        = aws_security_group.ecs_tasks.id
  source_security_group_id = aws_security_group.alb.id
  from_port                = tonumber(each.value)
  to_port                  = tonumber(each.value)
  protocol                 = "tcp"
  description              = "ALB to container port ${each.value}"
}

# Accepted exception: HTTPS-only egress to 0.0.0.0/0.
# AVD-AWS-0104 flags any egress to the whole internet regardless of port
# scope. ECS tasks genuinely need to reach ECR, CloudWatch/X-Ray,
# Secrets Manager, SQS and S3's public endpoints over TLS, and no VPC
# endpoints exist yet to keep that traffic inside the VPC. Already
# narrowed from all-ports/all-protocols to tcp/443 only. Owner: Hawaah.
# Revisit: add VPC interface endpoints (ecr.api, ecr.dkr, logs,
# secretsmanager, sqs) + an S3 gateway endpoint, then drop this rule
# entirely, post-G1.
#trivy:ignore:AVD-AWS-0104
resource "aws_security_group_rule" "ecs_egress_https" {
  type              = "egress"
  security_group_id = aws_security_group.ecs_tasks.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "ECR pull, CloudWatch/X-Ray export, Secrets Manager, SQS, S3 (HTTPS only)"
}

# Internal-only: the ALB security group has no ingress rule of its own
# (see comment above) other than from the API Gateway VPC Link. Making the
# ALB itself internal, in private subnets, means it also carries no public
# IP/DNS at the AWS level — API Gateway is the sole internet-facing edge.
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids

  # Standard hardening: reject requests with malformed/ambiguous headers
  # rather than passing them through to backends.
  drop_invalid_header_fields = true

  tags = var.tags
}

resource "aws_lb_target_group" "this" {
  for_each = local.services_by_name

  name        = "${var.name_prefix}-${each.key}-tg"
  port        = each.value.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = each.value.health_check_path
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }

  tags = var.tags
}

# Accepted exception: plain HTTP on an internal-only ALB.
# AVD-AWS-0054 flags this listener for not using HTTPS. This ALB is
# unreachable from the internet (internal = true, no public IP, SG allows
# ingress only from the API Gateway VPC Link SG) — API Gateway is the
# TLS-terminating public edge for this API. Adding HTTPS here would need
# an ACM certificate + domain, which is out of scope for the G1 capstone
# deadline. Owner: Hawaah. Revisit: add an internal ACM cert + HTTPS
# listener if this ALB ever gains a second, non-VPC-Link caller.
#trivy:ignore:AVD-AWS-0054
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[local.web_service.name].arn
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "backend_path" {
  for_each = { for s in local.backend_services : s.name => s }

  listener_arn = aws_lb_listener.http.arn
  priority     = local.backend_priorities[each.key]

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  condition {
    path_pattern {
      values = ["/${each.key}", "/${each.key}/*"]
    }
  }

  tags = var.tags
}
