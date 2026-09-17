variable "region" {
  description = "AWS region for the Terraform state backend."
  type        = string
  default     = "eu-west-3"
}

variable "name_prefix" {
  description = "Prefix applied to all bootstrap resource names."
  type        = string
  default     = "devops-g8"
}

variable "tags" {
  description = "Common tags applied to all bootstrap resources."
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
