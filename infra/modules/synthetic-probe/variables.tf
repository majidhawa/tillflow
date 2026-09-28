variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "devops-g8"
}

variable "target_url" {
  description = "URL the canary sends a GET request to every run (e.g. the API Gateway invoke URL)."
  type        = string
}

variable "schedule_expression" {
  description = "CloudWatch Synthetics schedule expression. The capstone brief requires a one-minute probe."
  type        = string
  default     = "rate(1 minute)"
}

variable "runtime_version" {
  description = "Synthetics canary runtime version. AWS periodically deprecates old runtime versions — verify this is still current with `aws synthetics describe-runtime-versions` before applying, don't trust this default blindly."
  type        = string
  default     = "syn-nodejs-puppeteer-9.1"
}

variable "artifact_expiration_days" {
  description = "Days before canary run artifacts (screenshots/logs/HAR files) are expired from S3."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Common tags applied to all resources in this module."
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
