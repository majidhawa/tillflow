output "dashboard_name" {
  description = "Name of the CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "dashboard_arn" {
  description = "ARN of the CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.this.dashboard_arn
}

output "alarm_names" {
  description = "Names of all alarms this module created, for evidence/reference."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.alb_unhealthy_hosts : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.alb_target_response_time : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.alb_target_5xx : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.ecs_cpu_high : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.ecs_memory_high : a.alarm_name],
    [aws_cloudwatch_metric_alarm.apigw_5xx.alarm_name],
    [aws_cloudwatch_metric_alarm.apigw_latency.alarm_name],
    [aws_cloudwatch_metric_alarm.synthetics_success_percent.alarm_name],
    [aws_cloudwatch_metric_alarm.synthetics_failed.alarm_name],
  )
}
