# Web -> API Gateway (HTTP API) -> VPC Link -> ALB -> ECS Fargate
#
# HTTP API (v2) VPC Links support integrating directly with an
# Application Load Balancer (unlike REST API v1 VPC Links, which require
# an NLB) — no ALB redesign is required for this integration to work.
#
# The ALB security group has no baked-in ingress rule of its own (see
# infra/modules/alb) — the only permitted ingress, from this module's VPC
# Link security group (output vpc_link_security_group_id) on the ALB
# listener port, is wired in infra/environments/dev/main.tf. That rule
# lives at the environment level rather than in either module because it
# needs outputs from both, and putting it in one or the other would
# create a circular module dependency.

resource "aws_security_group" "vpc_link" {
  name        = "${var.name_prefix}-apigw-vpclink-sg"
  description = "API Gateway VPC Link ENIs: egress to the ALB listener port only, no ingress"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-apigw-vpclink-sg"
  })
}

resource "aws_security_group_rule" "vpc_link_egress_to_alb" {
  type                     = "egress"
  security_group_id        = aws_security_group.vpc_link.id
  source_security_group_id = var.alb_security_group_id
  from_port                = var.alb_listener_port
  to_port                  = var.alb_listener_port
  protocol                 = "tcp"
  description              = "VPC Link to ALB listener"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.name_prefix}-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = var.private_subnet_ids

  tags = var.tags
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-http-api"
  protocol_type = "HTTP"

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id           = aws_apigatewayv2_api.this.id
  integration_type = "HTTP_PROXY"

  integration_uri    = var.alb_listener_arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id

  payload_format_version = "1.0"
}

# Single proxy-style default route forwards everything to the ALB, which
# does its own path-based routing to the four services' target groups.
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/apigw/${var.name_prefix}-http-api"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# Minimal resource policy scoped to this specific log group, not a
# blanket account-wide grant.
data "aws_iam_policy_document" "apigw_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.access_logs.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "apigw" {
  policy_name     = "${var.name_prefix}-apigw-access-logs"
  policy_document = data.aws_iam_policy_document.apigw_logs.json
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_logs.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  tags = var.tags

  depends_on = [aws_cloudwatch_log_resource_policy.apigw]
}
