output "api_id" {
  description = "ID of the HTTP API."
  value       = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  description = "Invoke URL for the default stage (auto-deployed)."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "vpc_link_id" {
  description = "ID of the API Gateway VPC Link."
  value       = aws_apigatewayv2_vpc_link.this.id
}

output "vpc_link_security_group_id" {
  description = "Security group ID attached to the API Gateway VPC Link ENIs. Used by the environment to scope the ALB's ingress rule to this source only."
  value       = aws_security_group.vpc_link.id
}
