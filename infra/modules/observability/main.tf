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

  # Shared Slack-alert contract fields (infra/modules/slack-alerts's Lambda
  # CONTRACT_FIELDS) that are identical across every alarm in this module.
  # contract_dashboard_url intentionally points at the real CloudWatch
  # dashboard this module creates below, not a Grafana URL — no Grafana
  # exists yet (see docs/slo-error-budgets.md's "what's still needed"
  # section). The Lambda's field name stays "grafana_panel" since that's
  # its actual, already-deployed contract field name.
  contract_owner         = "Hawaah (Reliability + Operations)"
  contract_dashboard_url = "https://console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${var.name_prefix}-tillflow-operations"
}

# --- ALB / target group health, per service ---

# Undeployed/disabled services (enable_services = false) simply never
# register targets, so this metric reports no data rather than an error.
# treat_missing_data = "notBreaching" means that state renders as OK, not
# ALARM — an undeployed service must never page anyone.
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  for_each = var.services

  alarm_name = "${var.name_prefix}-${each.key}-alb-unhealthy-hosts"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = each.key
    symptom           = "Unhealthy ECS targets behind the ALB"
    user_impact       = "Requests routed to ${each.key} may fail or time out until targets recover"
    observed_value    = "UnHealthyHostCount >= 1 (target group: ${each.key})"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#unhealthy-ecs-servicetasks"
    owner             = local.contract_owner
    first_safe_action = "Check aws ecs describe-services --cluster ${var.ecs_cluster_name} --services ${each.value.ecs_service_name} and tail container logs before taking any action"
  })
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

  alarm_name = "${var.name_prefix}-${each.key}-alb-latency-p90"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = each.key
    symptom           = "Elevated ALB target latency"
    user_impact       = "${each.key} requests are slower than the documented SLO target"
    observed_value    = "TargetResponseTime p90 > ${var.alb_latency_threshold_seconds}s (target group: ${each.key})"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#elevated-latency"
    owner             = local.contract_owner
    first_safe_action = "Check the ECS CPU/memory alarms for ${each.key} and confirm whether this is expected load (e.g. a k6 test) before scaling"
  })
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

  alarm_name = "${var.name_prefix}-${each.key}-alb-target-5xx"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = each.key
    symptom           = "Elevated 5xx responses from ${each.key}"
    user_impact       = "A portion of ${each.key} requests are failing"
    observed_value    = "HTTPCode_Target_5XX_Count >= ${var.alb_5xx_threshold} in 5 minutes (target group: ${each.key})"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#elevated-5xx"
    owner             = local.contract_owner
    first_safe_action = "Tail aws logs tail /ecs/${var.name_prefix}-${each.key} --since 15m --filter-pattern ERROR before taking any action"
  })
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

  alarm_name = "${var.name_prefix}-${each.key}-ecs-cpu-high"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = each.key
    symptom           = "High ECS CPU utilization"
    user_impact       = "${each.key} may become slow or start failing health checks if this continues"
    observed_value    = "CPUUtilization > ${var.ecs_cpu_threshold_percent}% (service: ${each.value.ecs_service_name})"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#high-ecs-cpumemory"
    owner             = local.contract_owner
    first_safe_action = "Confirm whether this is expected load (e.g. a k6 test) before considering a scale-up"
  })
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

  alarm_name = "${var.name_prefix}-${each.key}-ecs-memory-high"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = each.key
    symptom           = "High ECS memory utilization"
    user_impact       = "${each.key} risks OOM-related task restarts if this continues"
    observed_value    = "MemoryUtilization > ${var.ecs_memory_threshold_percent}% (service: ${each.value.ecs_service_name})"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#high-ecs-cpumemory"
    owner             = local.contract_owner
    first_safe_action = "Confirm whether this is expected load (e.g. a k6 test) before considering a scale-up"
  })
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
  alarm_name = "${var.name_prefix}-apigw-5xx"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = "api-gateway"
    symptom           = "Elevated API Gateway 5xx responses"
    user_impact       = "External requests across the golden path may be failing"
    observed_value    = "API Gateway 5xx >= ${var.apigw_5xx_threshold} in 5 minutes"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#elevated-5xx"
    owner             = local.contract_owner
    first_safe_action = "Check the per-service ALB 5xx and unhealthy-host alarms to find which backend is failing"
  })
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
  alarm_name = "${var.name_prefix}-apigw-latency"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = "api-gateway"
    symptom           = "Elevated API Gateway latency"
    user_impact       = "External requests across the golden path are slower than expected"
    observed_value    = "API Gateway average Latency > ${var.apigw_latency_threshold_ms}ms"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#elevated-latency"
    owner             = local.contract_owner
    first_safe_action = "Check the per-service ALB latency and ECS CPU/memory alarms to find which backend is slow"
  })
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
  alarm_name = "${var.name_prefix}-synthetic-probe-success-low"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = "synthetic-probe"
    symptom           = "External heartbeat canary success rate low"
    user_impact       = "The full external path (API Gateway -> ALB -> ECS) may be down or unreachable for real users"
    observed_value    = "SuccessPercent < ${var.synthetics_success_percent_threshold}% over 5 minutes"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#synthetic-probe-failure"
    owner             = local.contract_owner
    first_safe_action = "Check the ALB/API Gateway 5xx and unhealthy-host alarms first -- this is usually a downstream symptom"
  })
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
  alarm_name = "${var.name_prefix}-synthetic-probe-failed-runs"
  alarm_description = jsonencode({
    environment       = var.environment_name
    service           = "synthetic-probe"
    symptom           = "External heartbeat canary run failed"
    user_impact       = "The full external path (API Gateway -> ALB -> ECS) may be down or unreachable for real users"
    observed_value    = "Failed >= 1 in 5 minutes"
    grafana_panel     = local.contract_dashboard_url
    runbook_link      = "docs/runbook.md#synthetic-probe-failure"
    owner             = local.contract_owner
    first_safe_action = "Check the ALB/API Gateway 5xx and unhealthy-host alarms first -- this is usually a downstream symptom"
  })
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
