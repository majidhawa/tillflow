variable "region" {
  description = "AWS region for the dev environment."
  type        = string
  default     = "eu-west-3"
}

variable "name_prefix" {
  description = "Prefix applied to all dev resource names."
  type        = string
  default     = "devops-g8"
}

variable "vpc_cidr" {
  description = "CIDR block for the dev VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Two availability zones to spread subnets across."
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the two public subnets, one per AZ."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for the two private subnets (ECS tasks), one per AZ."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ, to keep the dev environment cheap."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to all dev resources."
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

# --- ECS golden path ---

variable "app_names" {
  description = "Short names of the four TillFlow services."
  type        = list(string)
  default     = ["web", "pos", "payments", "commission"]
}

variable "container_port" {
  description = "Port each application container listens on."
  type        = number
  default     = 8080
}

variable "image_tags" {
  description = "Immutable ECR image tag per service. \"pending\" is a placeholder only — it must be replaced with a real pushed tag before enable_services is set to true."
  type        = map(string)
  default = {
    web        = "pending"
    pos        = "pending"
    payments   = "pending"
    commission = "pending"
  }
}

variable "enable_services" {
  description = "Create the ECS services (and start tasks) for all four apps. Keep false until real images have been pushed to ECR under real tags — task definitions, cluster, ECR, IAM and logging are created either way."
  type        = bool
  default     = false
}

# --- RDS PostgreSQL ---

variable "rds_engine_version" {
  description = "PostgreSQL engine version. Verify against currently available RDS versions in eu-west-3 before apply."
  type        = string
  default     = "16.14"
}

variable "rds_instance_class" {
  description = "RDS instance class — smallest sensible size for lab/capstone use."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS allocated storage in GiB."
  type        = number
  default     = 20
}

variable "rds_db_name" {
  description = "Initial PostgreSQL database name."
  type        = string
  default     = "tillflow"
}

# --- Redis / Valkey ---

variable "redis_engine" {
  description = "ElastiCache engine: \"valkey\" or \"redis\"."
  type        = string
  default     = "valkey"
}

variable "redis_engine_version" {
  description = "Cache engine version."
  type        = string
  default     = "7.2"
}

variable "redis_node_type" {
  description = "Smallest sensible cache node type for lab/capstone use."
  type        = string
  default     = "cache.t4g.micro"
}

# --- SQS ---

variable "sqs_queue_name" {
  description = "Short name for the primary payment/event queue."
  type        = string
  default     = "payment-events"
}

# --- S3 ---

variable "s3_purposes" {
  description = "Purpose-separated bucket names to create."
  type        = list(string)
  default     = ["receipts", "reports", "audit"]
}

# --- EventBridge ---

variable "commission_schedule_expression" {
  description = "EventBridge schedule expression for the daily commission/reconciliation trigger."
  type        = string
  default     = "cron(0 2 * * ? *)"
}

# --- Secrets placeholders ---

variable "app_secret_placeholders" {
  description = "Configuration-reference-only secrets to create (no values). Populate real values out-of-band after apply."
  type = list(object({
    key         = string
    description = string
  }))
  default = [
    {
      key         = "daraja"
      description = "M-Pesa Daraja API credentials/config. Value must be set out-of-band, never committed."
    },
    {
      key         = "slack-webhook"
      description = "Slack webhook URL for operational notifications. Value must be set out-of-band, never committed."
    },
  ]
}
