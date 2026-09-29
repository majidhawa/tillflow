# G5 Fresh-Commit Release Evidence

## Release Commit

Fresh release commit:

`b9dd7493ae47026753bda5e0677aaccd58b7b958`

The Payments service image was built and stored in ECR using the full Git commit SHA as the immutable image tag.

ECR digest:

`sha256:59076a54aeb2608b4d98bd38ff37abaa648e6097f1be8ea67e5b38f5230d0e29`

## Terraform Deployment

The release was deployed through Terraform using a targeted Payments deployment because an unrelated Slack Lambda package hash drift was present in the full plan.

Apply result:

`Apply complete! Resources: 1 added, 1 changed, 1 destroyed.`

The replacement represents registration of a new immutable ECS task-definition revision and an in-place update of the ECS service.

## ECS Deployment Verification

Payments service after deployment:

- Desired tasks: 1
- Running tasks: 1
- Pending tasks: 0
- Task definition: `devops-g8-payments:8`
- Deployment status: `PRIMARY`
- Rollout state: `COMPLETED`

Running task status:

- Last status: `RUNNING`
- Health status: `HEALTHY`
- Payments image:
  `240462142849.dkr.ecr.eu-west-3.amazonaws.com/devops-g8-payments:b9dd7493ae47026753bda5e0677aaccd58b7b958`
- Runtime image digest:
  `sha256:59076a54aeb2608b4d98bd38ff37abaa648e6097f1be8ea67e5b38f5230d0e29`

The runtime digest exactly matched the digest recorded for the fresh ECR image.

## Load Balancer Verification

The newly deployed Payments target reported:

`healthy`

The previous task was observed in `draining` state during ECS deregistration, consistent with the rolling deployment.

## External Runtime Verification

Request:

`GET /payments/health`

Result:

`HTTP/2 200`

Response:

`payments: ok`

## Reproduction Commands

```bash
terraform plan \
  -target='module.ecs_service_payments.aws_ecs_task_definition.this' \
  -target='module.ecs_service_payments.aws_ecs_service.this[0]' \
  -out=g5-payments-release.tfplan

terraform apply "g5-payments-release.tfplan"

aws ecs wait services-stable \
  --cluster devops-g8-tillflow \
  --services devops-g8-payments \
  --region eu-west-3 \
  --profile devops-g8-new

aws ecs describe-services \
  --cluster devops-g8-tillflow \
  --services devops-g8-payments \
  --region eu-west-3 \
  --profile devops-g8-new

aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:eu-west-3:240462142849:targetgroup/devops-g8-payments-tg/62a75149ac21a86a \
  --region eu-west-3 \
  --profile devops-g8-new

curl -i https://c2po857caj.execute-api.eu-west-3.amazonaws.com/payments/health
```

## Result

PASS — a fresh Git commit was built as an immutable SHA-tagged image, deployed to ECS, reached a completed and healthy rollout, matched the expected ECR image digest at runtime, passed ALB health checks, and returned HTTP 200 through the public API.

## Additional Verification

- GitHub Actions **Build Images run 36644840281** succeeded for commit `b9dd7493ae47026753bda5e0677aaccd58b7b958`, linking the fresh commit to the immutable Payments image used by this release.
- The external `/payments/health` request returned `payments: ok` because the ALB/API routing reaches the Payments root handler. The Payments `/health` recovery is additionally demonstrated by the ECS task reporting `HEALTHY` and the Payments ALB target reporting `healthy`.
- A targeted Terraform apply was intentionally used to isolate the Payments release from unrelated Slack Lambda package-hash drift observed in the full Terraform plan. A full-plan reconciliation remains separate from this release proof.
