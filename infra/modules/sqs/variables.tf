variable "name_prefix" {
  description = "Prefix applied to all queue names."
  type        = string
  default     = "devops-g8"
}

variable "queue_name" {
  description = "Short name for the primary queue (final name is {name_prefix}-{queue_name}, DLQ is {name_prefix}-{queue_name}-dlq)."
  type        = string
  default     = "payment-events"
}

variable "visibility_timeout_seconds" {
  description = "Visibility timeout for the primary queue."
  type        = number
  default     = 30
}

variable "message_retention_seconds" {
  description = "Message retention for the primary queue (default 4 days)."
  type        = number
  default     = 345600
}

variable "dlq_message_retention_seconds" {
  description = "Message retention for the DLQ (default 14 days, the SQS maximum)."
  type        = number
  default     = 1209600
}

variable "max_receive_count" {
  description = "Number of failed receives before a message is moved to the DLQ."
  type        = number
  default     = 5
}

variable "ecs_task_role_name" {
  description = "Name of the existing shared ECS task IAM role, to grant it send/receive access on this queue."
  type        = string
}

variable "tags" {
  description = "Common tags applied to all queue resources."
  type        = map(string)
  default = {
    owner       = "hawa"
    service     = "platform"
    group       = "8"
    environment = "capstone"
    managed-by  = "terraform"
    capstone    = "tillflow"
  }
}
