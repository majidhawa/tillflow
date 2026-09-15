output "terraform_role_arn" {
  description = "ARN of the role terraform.yml assumes via OIDC for plan/apply. Set as the AWS_TERRAFORM_ROLE_ARN repository variable."
  value       = aws_iam_role.github_terraform.arn
}

output "terraform_role_name" {
  description = "Name of the GitHub Actions Terraform role."
  value       = aws_iam_role.github_terraform.name
}

output "deploy_role_arn" {
  description = "ARN of the role build-images.yml assumes via OIDC for ECR push. Set as the AWS_DEPLOY_ROLE_ARN repository variable."
  value       = aws_iam_role.github_deploy.arn
}

output "deploy_role_name" {
  description = "Name of the GitHub Actions deploy (ECR push) role."
  value       = aws_iam_role.github_deploy.name
}
