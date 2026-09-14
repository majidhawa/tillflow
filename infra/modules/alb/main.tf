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

resource "aws_security_group_rule" "alb_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
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

resource "aws_security_group_rule" "ecs_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.ecs_tasks.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "ECR pull, CloudWatch/X-Ray export, etc."
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

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
