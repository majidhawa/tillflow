output "terraform_role_arn" {
  description = "ARN of the apply-only role terraform.yml's apply job assumes via OIDC (push to main, production environment). Set as the AWS_TERRAFORM_ROLE_ARN repository variable. Not assumable from a pull_request."
  value       = aws_iam_role.github_terraform.arn
}

output "terraform_role_name" {
  description = "Name of the GitHub Actions Terraform apply-only role."
  value       = aws_iam_role.github_terraform.name
}

output "terraform_plan_role_arn" {
  description = "ARN of the read-only role terraform.yml's PR plan job assumes via OIDC. Set as the AWS_TERRAFORM_PLAN_ROLE_ARN repository variable."
  value       = aws_iam_role.github_terraform_plan.arn
}

output "terraform_plan_role_name" {
  description = "Name of the GitHub Actions Terraform PR-plan (read-only) role."
  value       = aws_iam_role.github_terraform_plan.name
}

output "deploy_role_arn" {
  description = "ARN of the role build-images.yml assumes via OIDC for ECR push. Set as the AWS_DEPLOY_ROLE_ARN repository variable."
  value       = aws_iam_role.github_deploy.arn
}

output "deploy_role_name" {
  description = "Name of the GitHub Actions deploy (ECR push) role."
  value       = aws_iam_role.github_deploy.name
}
