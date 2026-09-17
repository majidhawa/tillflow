variable "name" {
  description = "Short service name (web, pos, payments, commission)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to the task family and ECS service name."
  type        = string
  default     = "devops-g8"
}

variable "region" {
  description = "AWS region (used for awslogs and OTEL config)."
  type        = string
  default     = "eu-west-3"
}

variable "cluster_arn" {
  description = "ARN of the ECS cluster to run this service on."
  type        = string
}

variable "execution_role_arn" {
  description = "ARN of the shared ECS task execution role."
  type        = string
}

variable "task_role_arn" {
  description = "ARN of the shared ECS task role."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group for this service's containers."
  type        = string
}

variable "image" {
  description = "Full ECR image URI including an immutable tag (e.g. <repo_url>:<tag>). Not used unless enable_service = true, but must always be a syntactically valid image reference for the task definition to register."
  type        = string
}

variable "container_port" {
  description = "Port the application container listens on."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "HTTP path used by the container health check."
  type        = string
  default     = "/health"
}

variable "cpu" {
  description = "Task-level CPU units (Fargate)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task-level memory in MiB (Fargate)."
  type        = number
  default     = 512
}

variable "is_backend" {
  description = "Backend services (pos/payments/commission) get an ADOT sidecar + OTEL env config. Web does not by default."
  type        = bool
  default     = false
}

variable "adot_image" {
  description = "Pinned AWS Distro for OpenTelemetry Collector image (never :latest)."
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.39.0"
}

variable "container_user" {
  description = "Non-root user for the application container, as \"uid:gid\"."
  type        = string
  default     = "1000:1000"
}

variable "read_only_root_filesystem" {
  description = "Run the application container with a read-only root filesystem."
  type        = bool
  default     = true
}

# --- Networking (from existing network/ALB modules) ---

variable "private_subnet_ids" {
  description = "Private subnet IDs (from the existing network module) for the ECS task ENIs."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for the ECS task ENIs (the ALB-only ecs_tasks security group)."
  type        = list(string)
}

variable "target_group_arn" {
  description = "ALB target group ARN to register the service with. Set to null to create the task definition without a load balancer attachment."
  type        = string
  default     = null
}

# --- Golden-path gating: no production images exist yet ---

variable "enable_service" {
  description = "Create the aws_ecs_service (and start tasks) for this app. Leave false until a real image has been pushed to ECR, so no ECS service attempts to pull a non-existent image."
  type        = bool
  default     = false
}

variable "desired_count" {
  description = "Desired task count once the service is enabled."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Common tags applied to this service's resources."
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
