# GitHub Actions OIDC IAM roles for the existing CI/CD workflows
# (.github/workflows/terraform.yml, .github/workflows/build-images.yml).
#
# This module does NOT create the OIDC provider itself — an
# aws_iam_openid_connect_provider for token.actions.githubusercontent.com
# already exists in this account, discovered below via data source rather
# than a hardcoded ARN/account ID.

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  repo_subject = "repo:${var.github_org}/${var.github_repo}"

  ecs_execution_role_name = "${var.name_prefix}-ecs-execution"
  ecs_task_role_name      = "${var.name_prefix}-ecs-task"

  ecr_repository_arns = [
    for name in var.app_names :
    "arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.name_prefix}-${name}"
  ]
}

# --- Trust policies ---
#
# GitHub issues the OIDC token's `sub` claim differently depending on
# whether the job targets a GitHub Environment:
#   - pull_request, no environment:            repo:ORG/REPO:pull_request
#   - push to a branch, no environment:        repo:ORG/REPO:ref:refs/heads/<branch>
#   - any event, job has `environment: NAME`:  repo:ORG/REPO:environment:NAME
#     (this REPLACES the ref/pull_request form for that job)
#
# terraform.yml's `plan` job runs on pull_request with no environment, and
# its `apply` job targets `environment: production` — so the Terraform
# role must trust exactly those two subjects, not a branch-ref subject.

data "aws_iam_policy_document" "terraform_trust" {
  statement {
    sid     = "GithubActionsTerraformOidc"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.repo_subject}:pull_request",
        "${local.repo_subject}:environment:${var.github_environment}",
      ]
    }
  }
}

# build-images.yml only ever runs on `push` to main and never sets
# `environment:`, so it only ever presents the branch-ref subject.

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    sid     = "GithubActionsDeployOidc"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.repo_subject}:ref:refs/heads/${var.main_branch}"]
    }
  }
}

resource "aws_iam_role" "github_terraform" {
  name               = "${var.name_prefix}-github-terraform-role"
  description        = "Assumed via GitHub OIDC by terraform.yml (PR plan + main apply) for ${local.repo_subject}."
  assume_role_policy = data.aws_iam_policy_document.terraform_trust.json

  tags = var.tags
}

resource "aws_iam_role" "github_deploy" {
  name               = "${var.name_prefix}-github-deploy-role"
  description        = "Assumed via GitHub OIDC by build-images.yml (main pushes only) for ${local.repo_subject}."
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json

  tags = var.tags
}

# --- Deploy role permissions ---
# Minimum needed by build-images.yml: ECR auth + push image layers/tags
# to the four existing service repositories. No ECS/Terraform access.

data "aws_iam_policy_document" "deploy_permissions" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # account-level action, ECR does not support resource-level scoping here
  }

  statement {
    sid = "EcrPushTillflowServiceImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = local.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.name_prefix}-github-deploy-ecr-push"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.deploy_permissions.json
}

# --- Terraform role permissions ---
# Scoped to the AWS services infra/environments/dev actually manages
# (see infra/modules/*), plus remote state access. Deliberately NOT
# AdministratorAccess, and IAM management is constrained to devops-g8-*
# roles rather than being account-wide.

data "aws_iam_policy_document" "terraform_permissions" {

  # EC2 / VPC / networking (infra/modules/network, alb).
  # Most VPC-level EC2 actions have no resource-level ARN support in IAM
  # (CreateVpc, CreateSubnet, security group rule authorize/revoke, etc.
  # must be granted on "*"), so this statement is scoped by an explicit
  # action list instead of by resource.
  statement {
    sid = "Ec2Networking"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeSubnets",
      "ec2:DescribeRouteTables",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNatGateways",
      "ec2:DescribeAddresses",
      "ec2:DescribeAddressesAttribute",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeTags",
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:CreateNatGateway",
      "ec2:DeleteNatGateway",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["*"]
  }

  # Elastic Load Balancing v2 (infra/modules/alb). Create* actions on this
  # API generally require "*" (the target resource doesn't exist yet and
  # ELBv2 has no wildcard-name ARN pattern to pre-authorize against).
  statement {
    sid = "Elbv2"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:SetRulePriorities",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = ["*"]
  }

  # ECS cluster + services (infra/modules/ecs-cluster, ecs-service),
  # scoped to the one TillFlow cluster and its services.
  statement {
    sid = "EcsClusterAndServices"
    actions = [
      "ecs:CreateCluster",
      "ecs:DeleteCluster",
      "ecs:DescribeClusters",
      "ecs:PutClusterCapacityProviders",
      "ecs:UpdateClusterSettings",
      "ecs:CreateService",
      "ecs:UpdateService",
      "ecs:DeleteService",
      "ecs:DescribeServices",
      "ecs:TagResource",
      "ecs:UntagResource",
      "ecs:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ecs:${var.region}:${local.account_id}:cluster/${var.ecs_cluster_name}",
      "arn:aws:ecs:${var.region}:${local.account_id}:service/${var.ecs_cluster_name}/${var.name_prefix}-*",
    ]
  }

  # Task definitions, scoped by family name prefix.
  statement {
    sid = "EcsTaskDefinitions"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["arn:aws:ecs:${var.region}:${local.account_id}:task-definition/${var.name_prefix}-*:*"]
  }

  # List operations have no per-resource ARN form.
  statement {
    sid = "EcsListOnly"
    actions = [
      "ecs:ListClusters",
      "ecs:ListServices",
      "ecs:ListTaskDefinitions",
    ]
    resources = ["*"]
  }

  # ECR repositories (infra/modules/ecr) — the same four service repos
  # the deploy role pushes to.
  statement {
    sid = "EcrRepositoryManagement"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:PutImageScanningConfiguration",
      "ecr:PutImageTagMutability",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:ListTagsForResource",
    ]
    resources = local.ecr_repository_arns
  }

  # CloudWatch Logs (ECS app log groups + API Gateway access logs).
  statement {
    sid = "CloudWatchLogGroups"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/ecs/${var.name_prefix}-*",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/ecs/${var.name_prefix}-*:*",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/apigw/${var.name_prefix}-*",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/apigw/${var.name_prefix}-*:*",
    ]
  }

  # The API Gateway access-log resource policy (infra/modules/apigw-vpclink)
  # is an account-level object with no resource ARN of its own.
  statement {
    sid = "CloudWatchLogsResourcePolicy"
    actions = [
      "logs:PutResourcePolicy",
      "logs:DeleteResourcePolicy",
      "logs:DescribeResourcePolicies",
    ]
    resources = ["*"]
  }

  # API Gateway v2 (infra/modules/apigw-vpclink). API Gateway's IAM model
  # is HTTP-verb actions on path-shaped resources rather than per-operation
  # action names, so verb actions scoped to these paths is the narrowest
  # practical grant.
  statement {
    sid = "ApiGatewayV2"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
    ]
    resources = [
      "arn:aws:apigateway:${var.region}::/apis",
      "arn:aws:apigateway:${var.region}::/apis/*",
      "arn:aws:apigateway:${var.region}::/vpclinks",
      "arn:aws:apigateway:${var.region}::/vpclinks/*",
      "arn:aws:apigateway:${var.region}::/tags/*",
    ]
  }

  # RDS PostgreSQL (infra/modules/rds-postgres), scoped to the one instance
  # and its subnet group.
  statement {
    sid = "RdsPostgres"
    actions = [
      "rds:CreateDBInstance",
      "rds:DeleteDBInstance",
      "rds:ModifyDBInstance",
      "rds:DescribeDBInstances",
      "rds:CreateDBSubnetGroup",
      "rds:DeleteDBSubnetGroup",
      "rds:ModifyDBSubnetGroup",
      "rds:DescribeDBSubnetGroups",
      "rds:AddTagsToResource",
      "rds:RemoveTagsFromResource",
      "rds:ListTagsForResource",
    ]
    resources = [
      "arn:aws:rds:${var.region}:${local.account_id}:db:${var.name_prefix}-postgres",
      "arn:aws:rds:${var.region}:${local.account_id}:subgrp:${var.name_prefix}-postgres-subnet-group",
    ]
  }

  # ElastiCache / Valkey (infra/modules/redis), scoped to the one
  # replication group, its subnet group, and the cache cluster(s) AWS
  # creates underneath it.
  statement {
    sid = "ElastiCache"
    actions = [
      "elasticache:CreateReplicationGroup",
      "elasticache:DeleteReplicationGroup",
      "elasticache:ModifyReplicationGroup",
      "elasticache:DescribeReplicationGroups",
      "elasticache:DescribeCacheClusters",
      "elasticache:CreateCacheSubnetGroup",
      "elasticache:DeleteCacheSubnetGroup",
      "elasticache:ModifyCacheSubnetGroup",
      "elasticache:DescribeCacheSubnetGroups",
      "elasticache:IncreaseReplicaCount",
      "elasticache:DecreaseReplicaCount",
      "elasticache:AddTagsToResource",
      "elasticache:RemoveTagsFromResource",
      "elasticache:ListTagsForResource",
    ]
    resources = [
      "arn:aws:elasticache:${var.region}:${local.account_id}:replicationgroup:${var.name_prefix}-redis",
      "arn:aws:elasticache:${var.region}:${local.account_id}:subnetgroup:${var.name_prefix}-redis-subnet-group",
      "arn:aws:elasticache:${var.region}:${local.account_id}:cluster:${var.name_prefix}-redis*",
    ]
  }

  # SQS (infra/modules/sqs) — primary queue + DLQ, both under name_prefix.
  statement {
    sid = "Sqs"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:GetQueueAttributes",
      "sqs:SetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:TagQueue",
      "sqs:UntagQueue",
      "sqs:ListQueueTags",
    ]
    resources = ["arn:aws:sqs:${var.region}:${local.account_id}:${var.name_prefix}-*"]
  }

  # Application S3 buckets (infra/modules/s3-buckets) — receipts/reports/
  # audit. Bucket names carry a random suffix, so scoped by name_prefix.
  statement {
    sid = "AppS3Buckets"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucketVersioning",
      "s3:GetBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:GetBucketTagging",
      "s3:GetBucketLocation",
      "s3:GetBucketAcl",
      "s3:ListBucket",
    ]
    resources = ["arn:aws:s3:::${var.name_prefix}-*"]
  }

  # Terraform remote state: read/write only the dev state object (and its
  # lock helper objects) in the existing bootstrap bucket — not the whole
  # bucket, and never other environments' keys.
  statement {
    sid = "TerraformStateObject"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${var.terraform_state_bucket_name}/${var.terraform_state_key}",
      "arn:aws:s3:::${var.terraform_state_bucket_name}/${var.terraform_state_key}.tflock",
    ]
  }

  statement {
    sid       = "TerraformStateBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = ["arn:aws:s3:::${var.terraform_state_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.terraform_state_key}*"]
    }
  }

  # Terraform state locking (infra/bootstrap DynamoDB table).
  statement {
    sid = "TerraformStateLock"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = ["arn:aws:dynamodb:${var.region}:${local.account_id}:table/${var.terraform_lock_table_name}"]
  }

  # EventBridge (infra/modules/eventbridge-schedule) — no targets are
  # wired yet, so no events:PutTargets/RemoveTargets grant.
  statement {
    sid = "EventBridgeSchedule"
    actions = [
      "events:PutRule",
      "events:DeleteRule",
      "events:DescribeRule",
      "events:EnableRule",
      "events:DisableRule",
      "events:TagResource",
      "events:UntagResource",
      "events:ListTagsForResource",
    ]
    resources = ["arn:aws:events:${var.region}:${local.account_id}:rule/${var.name_prefix}-*"]
  }

  # Secrets Manager (RDS credentials + app secret placeholders), scoped to
  # name_prefix-owned secrets only. Terraform never reads out a value that
  # isn't already destined for its own state (the RDS module writes the
  # secret version it creates); no credentials are exposed by this grant
  # beyond what the affected modules already put in state.
  statement {
    sid = "SecretsManager"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
    ]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${var.name_prefix}-*"]
  }

  # IAM: constrained to devops-g8-* roles/policies only — this role can
  # manage the roles this Terraform config defines (ecs-execution,
  # ecs-task, and the two github-oidc-roles roles below, including
  # itself), but nothing outside that prefix.
  statement {
    sid = "ManageDevopsG8Roles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]
  }

  # Attaching the AWS-managed ECS execution policy is restricted to that
  # one managed policy and the one execution role — not general
  # AttachRolePolicy over any policy/role.
  statement {
    sid       = "AttachEcsExecutionManagedPolicy"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.ecs_execution_role_name}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
    }
  }

  # PassRole is limited to the two ECS runtime roles, and only when the
  # role is being passed to the ECS tasks service — never a blanket grant.
  statement {
    sid     = "PassEcsRolesToEcsTasks"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.ecs_execution_role_name}",
      "arn:aws:iam::${local.account_id}:role/${local.ecs_task_role_name}",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # First-time creation of the ALB (and, if not already present, Fargate
  # service networking) triggers AWS to auto-create the corresponding
  # service-linked role. Scoped to exactly those two predictable SLR ARNs,
  # gated by iam:AWSServiceName — not a general CreateServiceLinkedRole
  # grant.
  statement {
    sid     = "CreateAwsServiceLinkedRoles"
    actions = ["iam:CreateServiceLinkedRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing",
      "arn:aws:iam::${local.account_id}:role/aws-service-role/ecs.amazonaws.com/AWSServiceRoleForECS",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com", "ecs.amazonaws.com"]
    }
  }

  # Reading the existing GitHub OIDC provider (data source lookup done by
  # this very module) — read-only, no aws_iam_openid_connect_provider
  # create/delete permission is granted anywhere in this policy.
  statement {
    sid       = "ListOidcProviders"
    actions   = ["iam:ListOpenIDConnectProviders"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadGithubOidcProvider"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = ["arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"]
  }

  # Read-only identity/region calls the AWS/Terraform providers make.
  statement {
    sid       = "StsIdentity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "terraform" {
  name   = "${var.name_prefix}-github-terraform-permissions"
  role   = aws_iam_role.github_terraform.id
  policy = data.aws_iam_policy_document.terraform_permissions.json
}
