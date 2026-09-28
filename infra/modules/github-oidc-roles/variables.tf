variable "name_prefix" {
  description = "Prefix applied to both IAM role names."
  type        = string
  default     = "devops-g8"
}

variable "region" {
  description = "AWS region the managed infrastructure lives in. Used only to build resource ARNs, never to select a provider."
  type        = string
  default     = "eu-west-3"
}

variable "github_org" {
  description = "GitHub organization/user that owns the repository allowed to assume these roles."
  type        = string
  default     = "majidhawa"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume these roles (org/user scoped separately via github_org)."
  type        = string
  default     = "tillflow"
}

variable "github_org_id" {
  description = "Numeric GitHub owner ID used in this repository's customized OIDC subject claim."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID used in this repository's customized OIDC subject claim."
  type        = string
}

variable "github_environment" {
  description = "GitHub Environment name used by terraform.yml's apply job. GitHub issues the OIDC subject as repo:ORG/REPO:environment:NAME for any job that targets an environment, regardless of branch."
  type        = string
  default     = "production"
}

variable "main_branch" {
  description = "Branch build-images.yml pushes are restricted to."
  type        = string
  default     = "main"
}

variable "ecs_cluster_name" {
  description = "Name of the existing ECS Fargate cluster (infra/modules/ecs-cluster)."
  type        = string
  default     = "devops-g8-tillflow"
}

variable "app_names" {
  description = "Short names of the four TillFlow services. Used to scope ECR/ECS/ALB permissions to the resources those services actually use."
  type        = list(string)
  default     = ["web", "pos", "payments", "commission"]
}

variable "terraform_state_bucket_name" {
  description = "Name of the existing S3 bucket holding Terraform state (infra/bootstrap). Has a generated suffix, so it is passed in rather than derived from name_prefix."
  type        = string
}

variable "terraform_state_key" {
  description = "State object key within the state bucket that infra/environments/dev uses, from backend.tf."
  type        = string
  default     = "tillflow/dev/terraform.tfstate"
}

variable "terraform_lock_table_name" {
  description = "Name of the existing DynamoDB table used for state locking (infra/bootstrap)."
  type        = string
  default     = "devops-g8-terraform-locks"
}

variable "tags" {
  description = "Common tags applied to both IAM roles."
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
