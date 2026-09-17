variable "name_prefix" {
  description = "Prefix applied to all secret names."
  type        = string
  default     = "devops-g8"
}

variable "secrets" {
  description = "Configuration-reference-only secrets to create. No secret_string/version is ever created by this module — values must be set out-of-band (console, CLI, or a separate, non-committed process)."
  type = list(object({
    key         = string
    description = string
  }))
  default = [
    {
      key         = "daraja"
      description = "M-Pesa Daraja API credentials/config. Value must be set out-of-band, never committed."
    },
    {
      key         = "slack-webhook"
      description = "Slack webhook URL for operational notifications. Value must be set out-of-band, never committed."
    },
  ]
}

variable "ecs_task_role_name" {
  description = "Name of the existing shared ECS task IAM role, to grant it read access to these secrets."
  type        = string
}

variable "tags" {
  description = "Common tags applied to all secret resources."
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
