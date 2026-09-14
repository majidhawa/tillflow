output "queue_url" {
  description = "URL of the primary queue."
  value       = aws_sqs_queue.this.id
}

output "queue_arn" {
  description = "ARN of the primary queue."
  value       = aws_sqs_queue.this.arn
}

output "dlq_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.dlq.id
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue."
  value       = aws_sqs_queue.dlq.arn
}
