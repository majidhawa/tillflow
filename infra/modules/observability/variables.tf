variable "name_prefix" {
  description = "Prefix applied to alarm and dashboard names."
  type        = string
}

variable "region" {
  description = "AWS region (used to build the dashboard's console links)."
  type        = string
}

variable "environment_name" {
  description = "Environment label included in each alarm's Slack-alert contract fields (infra/modules/slack-alerts's Lambda CONTRACT_FIELDS), matching the environment_name already passed to that module."
  type        = string
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for alarm_actions/ok_actions (infra/modules/slack-alerts alerts_topic_arn)."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (CloudWatch LoadBalancer dimension form), from infra/modules/alb's alb_arn_suffix output."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name, from infra/modules/ecs-cluster's cluster_name output."
  type        = string
}

variable "api_gateway_id" {
  description = "HTTP API ID, from infra/modules/apigw-vpclink's api_id output."
  type        = string
}

variable "api_gateway_stage_name" {
  description = "API Gateway stage name. infra/modules/apigw-vpclink always deploys the auto-deployed \"$default\" stage."
  type        = string
  default     = "$default"
}

variable "synthetics_canary_name" {
  description = "Canary name, from infra/modules/synthetic-probe's canary_name output."
  type        = string
}

variable "services" {
  description = "Per-service dimensions needed for ALB target-group and ECS service alarms/widgets. ecs_service_name is the deployed ECS service name (deterministically name_prefix + \"-\" + service, matching infra/modules/ecs-service's internal naming) — it is used as a metric dimension even when the service doesn't exist yet (enable_services = false); such alarms simply see no data (see treat_missing_data on ECS/target-group alarms below), not an error."
  type = map(object({
    target_group_arn_suffix = string
    ecs_service_name        = string
  }))
}

# --- Threshold knobs. Defaults are deliberately loose enough not to false-
# alarm on an idle dev environment, but tight enough to trip during a
# deliberate k6 load test or fault injection during the incident demo. ---

variable "alb_latency_threshold_seconds" {
  description = "ALB TargetResponseTime alarm threshold, in seconds (ALB publishes this metric in seconds, not ms)."
  type        = number
  default     = 1
}

variable "alb_5xx_threshold" {
  description = "Target-level HTTPCode_Target_5XX_Count alarm threshold (sum per 5-minute period)."
  type        = number
  default     = 5
}

variable "ecs_cpu_threshold_percent" {
  description = "ECS service CPUUtilization alarm threshold (percent)."
  type        = number
  default     = 80
}

variable "ecs_memory_threshold_percent" {
  description = "ECS service MemoryUtilization alarm threshold (percent)."
  type        = number
  default     = 80
}

variable "apigw_5xx_threshold" {
  description = "API Gateway 5xx alarm threshold (sum per 5-minute period)."
  type        = number
  default     = 5
}

variable "apigw_latency_threshold_ms" {
  description = "API Gateway Latency alarm threshold, in milliseconds (API Gateway publishes this metric in ms, unlike the ALB's seconds)."
  type        = number
  default     = 1000
}

variable "synthetics_success_percent_threshold" {
  description = "CloudWatch Synthetics SuccessPercent alarm floor (percent). Alarms if average success over the evaluation window drops below this."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Common tags applied to alarm and dashboard resources."
  type        = map(string)
  default     = {}
}
