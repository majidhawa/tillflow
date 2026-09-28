variable "name_prefix" {
  description = "Prefix applied to all cache resource names."
  type        = string
  default     = "devops-g8"
}

variable "vpc_id" {
  description = "VPC ID (from the existing network module)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (from the existing network module) for the cache subnet group."
  type        = list(string)
}

variable "ecs_tasks_security_group_id" {
  description = "Security group ID of the existing ECS tasks (from the alb module) — the only allowed ingress source."
  type        = string
}

variable "engine" {
  description = "ElastiCache engine: \"valkey\" (recommended, AWS-supported Redis OSS fork) or \"redis\"."
  type        = string
  default     = "valkey"
}

variable "engine_version" {
  description = "Engine version."
  type        = string
  default     = "7.2"
}

variable "node_type" {
  description = "Smallest sensible node type for lab/capstone use."
  type        = string
  default     = "cache.t4g.micro"
}

variable "tags" {
  description = "Common tags applied to all cache resources."
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
