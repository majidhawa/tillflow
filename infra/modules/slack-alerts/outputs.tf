output "alerts_topic_arn" {
  description = "SNS topic ARN. Point aws_cloudwatch_metric_alarm's alarm_actions/ok_actions here."
  value       = aws_sns_topic.alerts.arn
}
