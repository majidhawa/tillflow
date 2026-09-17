variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "devops-g8"
}

variable "slack_webhook_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Slack incoming-webhook URL (see infra/modules/secrets-placeholders' \"slack-webhook\" entry). The secret value must be set out-of-band, never in Terraform."
  type        = string
}

variable "environment_name" {
  description = "Environment label included in every Slack message (e.g. \"dev\", \"capstone\")."
  type        = string
  default     = "capstone"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the notifier Lambda's own logs."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Common tags applied to all resources in this module."
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
