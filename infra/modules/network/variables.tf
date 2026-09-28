variable "name_prefix" {
  description = "Prefix applied to all network resource names."
  type        = string
  default     = "devops-g8"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
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
  description = "Use one shared NAT gateway instead of one per AZ, to keep the capstone footprint cheap. Set to false for full AZ-redundant NAT."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to all network resources."
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
