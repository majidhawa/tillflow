output "rule_arn" {
  description = "ARN of the schedule rule."
  value       = aws_cloudwatch_event_rule.this.arn
}

output "rule_name" {
  description = "Name of the schedule rule."
  value       = aws_cloudwatch_event_rule.this.name
}
