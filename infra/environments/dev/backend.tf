# S3 backend for the dev environment state, using the bucket and
# DynamoDB lock table created by infra/bootstrap.

terraform {
  backend "s3" {
    bucket         = "devops-g8-terraform-state-a8a9220d"
    key            = "tillflow/dev/terraform.tfstate"
    region         = "eu-west-3"
    dynamodb_table = "devops-g8-terraform-locks"
    encrypt        = true
  }
}
