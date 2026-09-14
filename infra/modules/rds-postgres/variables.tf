variable "name_prefix" {
  description = "Prefix applied to all RDS resource names."
  type        = string
  default     = "devops-g8"
}

variable "vpc_id" {
  description = "VPC ID (from the existing network module)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (from the existing network module) for the DB subnet group."
  type        = list(string)
}

variable "ecs_tasks_security_group_id" {
  description = "Security group ID of the existing ECS tasks (from the alb module) — the only allowed ingress source."
  type        = string
}

variable "ecs_task_role_name" {
  description = "Name of the existing shared ECS task IAM role, to grant it read access to the generated DB secret."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version. Verify against currently available RDS versions in eu-west-3 before apply."
  type        = string
  default     = "16.14"
}

variable "instance_class" {
  description = "RDS instance class — smallest sensible size for lab/capstone use."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "tillflow"
}

variable "master_username" {
  description = "Master username (not a secret value itself; the password is generated and stored in Secrets Manager)."
  type        = string
  default     = "tillflow_admin"
}

variable "backup_retention_period" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Lab use: may be false."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Lab use: may be true."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to all RDS resources."
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
