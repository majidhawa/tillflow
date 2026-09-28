variable "name_prefix" {
  description = "Prefix applied to the rule name."
  type        = string
  default     = "devops-g8"
}

variable "rule_name" {
  description = "Short name for the rule (final name is {name_prefix}-{rule_name})."
  type        = string
  default     = "commission-reconciliation-daily"
}

variable "description" {
  description = "Description of what this schedule is for."
  type        = string
  default     = "Daily trigger for the commission/reconciliation job. No target wired yet — see module README comment in main.tf."
}

variable "schedule_expression" {
  description = "EventBridge schedule expression (cron or rate)."
  type        = string
  default     = "cron(0 2 * * ? *)"
}

variable "enabled" {
  description = "Whether the rule is enabled. Consider leaving disabled until a real target exists, to avoid a silently-firing no-op rule."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to this rule."
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
