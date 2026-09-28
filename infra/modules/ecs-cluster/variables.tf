variable "cluster_name" {
  description = "Name of the ECS Fargate cluster."
  type        = string
  default     = "devops-g8-tillflow"
}

variable "name_prefix" {
  description = "Prefix applied to IAM roles and log groups."
  type        = string
  default     = "devops-g8"
}

variable "service_names" {
  description = "Short service names to create CloudWatch log groups for."
  type        = list(string)
  default     = ["web", "pos", "payments", "commission"]
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Common tags applied to all cluster/IAM/log resources."
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
