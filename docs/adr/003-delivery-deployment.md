# ADR-003: Delivery and Deployment Architecture

- Status: Accepted
- Date: 2026-09-14
- Group: 8
- AWS Region: eu-west-3

## Context

TillFlow requires a reproducible delivery process for application services and infrastructure.

The delivery design must support:

- pull-request validation
- infrastructure validation
- secure AWS authentication
- immutable container images
- controlled deployment to ECS
- smoke verification
- rollback on failed release
- traceable evidence for assessment

The platform must avoid long-lived AWS credentials in GitHub.

## Decision

TillFlow will use a two-stage delivery model:

1. GitHub Actions for pull-request and pre-merge validation
2. AWS CodePipeline / CodeBuild for deployment execution

Infrastructure will be managed using Terraform.

Application services will be containerized and published to Amazon ECR.

Deployments will update Amazon ECS services using immutable image references.

## Pull Request Validation

GitHub Actions will run validation for relevant changed paths.

The PR lane will include, where applicable:

- formatting checks
- linting
- type checking
- unit tests
- integration tests
- Terraform formatting and validation
- Terraform plan
- secret scanning
- dependency scanning
- infrastructure-as-code scanning
- Docker image build validation
- SBOM generation
- container vulnerability scanning

A failed required validation blocks the delivery decision.

## Path-Aware Validation

Workflows should avoid rebuilding every service for unrelated changes.

Path filters or matrices will be used so changes under:

- `services/web/`
- `services/pos/`
- `services/payments/`
- `services/commission/`
- `infra/`

trigger only the relevant validation and build jobs where practical.

Shared changes under `services/_shared/` may trigger validation for multiple dependent services.

## AWS Authentication

GitHub Actions will authenticate to AWS using OpenID Connect.

Long-lived AWS access keys must not be stored in GitHub secrets.

The GitHub OIDC role must follow least privilege and be scoped to the required repository and branch conditions where possible.

## Terraform Flow

Terraform is the source of truth for AWS infrastructure.

The intended infrastructure flow is:

Pull Request
-> terraform fmt/check
-> terraform validate
-> security scan
-> terraform plan
-> human review
-> merge to main
-> approved terraform apply

Terraform state must use remote state with:

- Amazon S3
- encryption
- versioning
- public access block
- DynamoDB state locking

Infrastructure applies must target only the assigned region:

`eu-west-3`

Resources must follow the required prefix:

`devops-g8-`

## Application Build Flow

For each deployable service:

Source
-> test
-> container build
-> SBOM
-> vulnerability scan
-> push to ECR
-> ECS deployment
-> smoke test

Images must be tagged using immutable identifiers such as:

- Git commit SHA
- image digest

The `latest` tag must not be used for production deployment decisions.

## ECR

Separate ECR repositories will be created for:

- web
- pos
- payments
- commission

Images must be traceable back to source commits.

Repository scanning and image lifecycle management will be configured where appropriate.

## CodePipeline and CodeBuild

AWS CodePipeline will coordinate deployment stages.

CodeBuild may perform:

- application build
- tests
- container build
- vulnerability checks
- ECR push
- deployment preparation
- smoke validation

The deployment pipeline must preserve enough logs and metadata to demonstrate:

- source commit
- build result
- image identity
- deployment result
- smoke result

## ECS Deployment

Each service will deploy to its corresponding ECS service.

Deployments must use immutable image references.

ECS health checks and application readiness endpoints will be used to determine deployment health.

Required application endpoints include:

- `/health`
- `/ready`

A deployment must not be considered successful only because the ECS task started.

Application readiness must also be verified.

## Smoke Verification

Post-deployment smoke tests will verify that the deployed path is functional.

At minimum, smoke tests should verify:

- public ingress is reachable where applicable
- routing reaches the correct service
- `/health` responds successfully
- `/ready` responds successfully
- critical dependency checks behave as expected

Smoke test results must be retained as evidence.

## Rollback

A failed deployment or failed post-deployment smoke test must trigger or support rollback to the last known-good release.

Rollback evidence must identify:

- failed version
- previous known-good version
- rollback action
- restored health result

The release process must make rollback faster than rebuilding an unknown version.

## Container Security

Service containers must use:

- pinned base images
- non-root execution where supported
- minimal runtime dependencies
- read-only filesystem where practical
- explicit health checks

Secrets must not be baked into container images.

## Secrets

Runtime secrets will be stored in AWS Secrets Manager.

Secrets must not be committed to source control or printed in pipeline logs.

GitHub Actions will use OIDC for AWS access rather than static AWS credentials.

## Observability During Deployment

Deployment events must be observable.

Where possible, release metadata should include:

- service name
- Git commit SHA
- image digest
- deployment timestamp
- environment

This metadata should make it possible to correlate runtime failures with a release.

## Evidence

Delivery evidence will be stored under:

`evidence/platform/`

Evidence should include reproducible command output, pipeline logs, plans, deployment identifiers, and smoke results.

Screenshots may supplement evidence but must not be the only proof.

## Consequences

### Positive

- Strong separation between validation and deployment execution
- Reduced exposure of long-lived AWS credentials
- Immutable releases are easier to trace and roll back
- Path-aware workflows reduce unnecessary builds
- Terraform changes are reviewed before apply
- Deployment evidence can be reproduced and defended

### Trade-offs

- Two delivery systems increase initial setup complexity
- OIDC and IAM trust policies require careful configuration
- Path filtering must be maintained as repository structure changes
- Build and scan stages may increase pipeline duration
- Rollback behavior must be tested rather than assumed

## Ownership

Platform + Delivery is owned by Hawa.

Glory reviews Platform + Delivery changes according to the agreed cross-review model.

Domain DRIs remain responsible for their service tests and application correctness.
