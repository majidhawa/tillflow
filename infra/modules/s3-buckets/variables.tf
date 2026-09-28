variable "name_prefix" {
  description = "Prefix applied to all bucket names."
  type        = string
  default     = "devops-g8"
}

variable "purposes" {
  description = "Short purpose names, one bucket per entry (final name is {name_prefix}-{purpose}-{random suffix})."
  type        = list(string)
  default     = ["receipts", "reports", "audit"]
}

variable "noncurrent_version_expiration_days" {
  description = "Days before a noncurrent object version is expired, in every purpose bucket. Applies to old versions only, never the current object."
  type        = number
  default     = 90
}

variable "expiration_days" {
  description = "Optional per-purpose expiration for CURRENT objects, e.g. { artifacts = 90 }. Purposes not listed here keep their objects indefinitely (appropriate for audit/evidence/backups)."
  type        = map(number)
  default     = {}
}

variable "ecs_task_role_name" {
  description = "Name of the existing shared ECS task IAM role, to grant it read/write access to these buckets."
  type        = string
}

variable "tags" {
  description = "Common tags applied to all bucket resources."
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
