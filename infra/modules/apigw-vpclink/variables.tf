variable "name_prefix" {
  description = "Prefix applied to all API Gateway resource names."
  type        = string
  default     = "devops-g8"
}

variable "vpc_id" {
  description = "VPC ID (from the existing network module)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (from the existing network module) for the VPC Link ENIs."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID of the existing ALB (from the alb module). The VPC Link's own security group is granted egress to it, not the other way around."
  type        = string
}

variable "alb_listener_arn" {
  description = "ARN of the existing ALB HTTP listener (from the alb module) — the private integration target."
  type        = string
}

variable "alb_listener_port" {
  description = "Port of the existing ALB HTTP listener."
  type        = number
  default     = 80
}

variable "log_retention_days" {
  description = "Retention for the API Gateway access log group."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Common tags applied to all API Gateway resources."
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
