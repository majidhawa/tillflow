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
