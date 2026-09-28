# CloudWatch observability for the G1 golden path: ALB/target health, ECS
# CPU/memory, API Gateway errors/latency, and the external Synthetics
# canary — plus one dashboard tying them together. All alarms wire to the
# existing Slack SNS topic (infra/modules/slack-alerts); this module does
# not create or modify that topic, the ALB, ECS services, API Gateway, or
# the canary itself.
#
# Every dimension value below comes from an existing module output (see
# variables.tf) — none are invented here.

locals {
  alarm_actions = [var.alarm_sns_topic_arn]
}

# --- ALB / target group health, per service ---

# Undeployed/disabled services (enable_services = false) simply never
# register targets, so this metric reports no data rather than an error.
# treat_missing_data = "notBreaching" means that state renders as OK, not
# ALARM — an undeployed service must never page anyone.
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  for_each = var.services

  alarm_name          = "${var.name_prefix}-${each.key}-alb-unhealthy-hosts"
  alarm_description   = "One or more unhealthy targets behind the ${each.key} target group."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.value.target_group_arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_response_time" {
  for_each = var.services

  alarm_name          = "${var.name_prefix}-${each.key}-alb-latency-p90"
  alarm_description   = "${each.key} p90 target response time above ${var.alb_latency_threshold_seconds}s."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p90"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.alb_latency_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.value.target_group_arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  for_each = var.services

  alarm_name          = "${var.name_prefix}-${each.key}-alb-target-5xx"
  alarm_description   = "${each.key} target group returned ${var.alb_5xx_threshold}+ 5xx responses in 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alb_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.value.target_group_arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

# --- ECS CPU / memory, per service ---
#
# ecs_service_name is the deterministic name the service WOULD have once
# enabled ("${name_prefix}-${service}"), not a lookup of a live resource.
# While enable_services = false, AWS/ECS never publishes data for a
# service that doesn't exist, so these alarms sit at notBreaching/OK
# indefinitely instead of alarming on an undeployed service.

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  for_each = var.services

  alarm_name          = "${var.name_prefix}-${each.key}-ecs-cpu-high"
  alarm_description   = "${each.key} ECS service CPUUtilization above ${var.ecs_cpu_threshold_percent}%."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.ecs_cpu_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = each.value.ecs_service_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  for_each = var.services

  alarm_name          = "${var.name_prefix}-${each.key}-ecs-memory-high"
  alarm_description   = "${each.key} ECS service MemoryUtilization above ${var.ecs_memory_threshold_percent}%."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.ecs_memory_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = each.value.ecs_service_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

# --- API Gateway (HTTP API v2): 5xx + latency ---
# Metric names/dimensions confirmed against AWS's HTTP API metrics
# reference: "5xx" and "Latency" (not the REST-API-v1 "5XXError" form),
# dimensions ApiId + Stage.

resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${var.name_prefix}-apigw-5xx"
  alarm_description   = "API Gateway returned ${var.apigw_5xx_threshold}+ 5xx responses in 5 minutes."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.apigw_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_gateway_id
    Stage = var.api_gateway_stage_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "apigw_latency" {
  alarm_name          = "${var.name_prefix}-apigw-latency"
  alarm_description   = "API Gateway average latency above ${var.apigw_latency_threshold_ms}ms."
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.apigw_latency_threshold_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_gateway_id
    Stage = var.api_gateway_stage_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

# --- CloudWatch Synthetics: the external heartbeat canary ---
# Metric names/dimension confirmed against AWS's Synthetics metrics
# reference: "SuccessPercent" and "Failed", dimension CanaryName.

resource "aws_cloudwatch_metric_alarm" "synthetics_success_percent" {
  alarm_name          = "${var.name_prefix}-synthetic-probe-success-low"
  alarm_description   = "External heartbeat canary success rate below ${var.synthetics_success_percent_threshold}% over 5 minutes."
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.synthetics_success_percent_threshold
  comparison_operator = "LessThanThreshold"
  # notBreaching, not "missing": right after this canary is first created,
  # or if it's ever paused, there's a brief window with no runs yet. That
  # absence of data must never look like an active incident.
  treat_missing_data = "notBreaching"

  dimensions = {
    CanaryName = var.synthetics_canary_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "synthetics_failed" {
  alarm_name          = "${var.name_prefix}-synthetic-probe-failed-runs"
  alarm_description   = "External heartbeat canary had a failed run in the last 5 minutes."
  namespace           = "CloudWatchSynthetics"
  metric_name         = "Failed"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    CanaryName = var.synthetics_canary_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = var.tags
}

# --- Dashboard ---

locals {
  service_names = sort(keys(var.services))

  alb_latency_metrics = [
    for name in local.service_names : [
      "AWS/ApplicationELB", "TargetResponseTime",
      "LoadBalancer", var.alb_arn_suffix,
      "TargetGroup", var.services[name].target_group_arn_suffix,
      { label = name, stat = "p90" }
    ]
  ]

  alb_unhealthy_metrics = [
    for name in local.service_names : [
      "AWS/ApplicationELB", "UnHealthyHostCount",
      "LoadBalancer", var.alb_arn_suffix,
      "TargetGroup", var.services[name].target_group_arn_suffix,
      { label = name, stat = "Maximum" }
    ]
  ]

  alb_5xx_metrics = [
    for name in local.service_names : [
      "AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",
      "LoadBalancer", var.alb_arn_suffix,
      "TargetGroup", var.services[name].target_group_arn_suffix,
      { label = name, stat = "Sum" }
    ]
  ]

  ecs_cpu_metrics = [
    for name in local.service_names : [
      "AWS/ECS", "CPUUtilization",
      "ClusterName", var.ecs_cluster_name,
      "ServiceName", var.services[name].ecs_service_name,
      { label = name, stat = "Average" }
    ]
  ]

  ecs_memory_metrics = [
    for name in local.service_names : [
      "AWS/ECS", "MemoryUtilization",
      "ClusterName", var.ecs_cluster_name,
      "ServiceName", var.services[name].ecs_service_name,
      { label = name, stat = "Average" }
    ]
  ]

  dashboard_body = {
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ALB target response time (p90, seconds)"
          view    = "timeSeries"
          region  = var.region
          metrics = local.alb_latency_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ALB unhealthy target count"
          view    = "timeSeries"
          region  = var.region
          metrics = local.alb_unhealthy_metrics
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "ALB target 5xx count"
          view    = "timeSeries"
          region  = var.region
          metrics = local.alb_5xx_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "ECS CPUUtilization (%)"
          view    = "timeSeries"
          region  = var.region
          metrics = local.ecs_cpu_metrics
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "ECS MemoryUtilization (%)"
          view    = "timeSeries"
          region  = var.region
          metrics = local.ecs_memory_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway 5xx + latency"
          view   = "timeSeries"
          region = var.region
          metrics = [
            ["AWS/ApiGateway", "5xx", "ApiId", var.api_gateway_id, "Stage", var.api_gateway_stage_name, { label = "5xx (sum)", stat = "Sum" }],
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_gateway_id, "Stage", var.api_gateway_stage_name, { label = "latency ms (avg)", stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Synthetic probe: success % + failed runs"
          view   = "timeSeries"
          region = var.region
          metrics = [
            ["CloudWatchSynthetics", "SuccessPercent", "CanaryName", var.synthetics_canary_name, { label = "success %", stat = "Average" }],
            ["CloudWatchSynthetics", "Failed", "CanaryName", var.synthetics_canary_name, { label = "failed runs (sum)", stat = "Sum", yAxis = "right" }],
          ]
        }
      },
    ]
  }
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name_prefix}-tillflow-operations"
  dashboard_body = jsonencode(local.dashboard_body)
}
