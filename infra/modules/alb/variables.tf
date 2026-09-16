variable "name_prefix" {
  description = "Prefix applied to all ALB/security-group/target-group names."
  type        = string
  default     = "devops-g8"
}

variable "vpc_id" {
  description = "VPC ID (from the existing network module) to place the ALB and security groups in."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs (from the existing network module) for the ALB. Private subnets, since the ALB is internal-only — reached solely via the API Gateway VPC Link, never directly from the internet."
  type        = list(string)
}

variable "listener_port" {
  description = "Public HTTP port the ALB listens on."
  type        = number
  default     = 80
}

variable "services" {
  description = "Backend services to create target groups + routing for. The first entry is used as the listener default action."
  type = list(object({
    name              = string
    container_port    = number
    health_check_path = string
  }))
  default = [
    { name = "web", container_port = 8080, health_check_path = "/" },
    { name = "pos", container_port = 8080, health_check_path = "/health" },
    { name = "payments", container_port = 8080, health_check_path = "/health" },
    { name = "commission", container_port = 8080, health_check_path = "/health" },
  ]
}

variable "tags" {
  description = "Common tags applied to all ALB resources."
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
