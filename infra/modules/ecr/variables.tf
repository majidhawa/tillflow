variable "name_prefix" {
  description = "Prefix applied to all repository names."
  type        = string
  default     = "devops-g8"
}

variable "repository_names" {
  description = "Short service names to create ECR repositories for (final name is {name_prefix}-{name})."
  type        = list(string)
  default     = ["web", "pos", "payments", "commission"]
}

variable "untagged_image_expiry_days" {
  description = "Days after which untagged images are expired by lifecycle policy."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Common tags applied to all ECR repositories."
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
