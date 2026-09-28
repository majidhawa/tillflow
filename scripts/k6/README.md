# k6 load test

`golden-path-load-test.js` exercises the deployed API Gateway -> VPC Link -> ALB -> ECS Fargate path using the endpoints the G1 golden-path stub services actually expose. See the comment block at the top of the script for full usage and rationale.

Install k6: https://k6.io/docs/get-started/installation/

```bash
BASE_URL=https://<api-id>.execute-api.eu-west-3.amazonaws.com k6 run scripts/k6/golden-path-load-test.js
```

Get `<api-id>` from the `api_gateway_endpoint` Terraform output (`infra/environments/dev/outputs.tf`), or the AWS Console.

See `docs/runbook.md` for the full incident-demo procedure this feeds into.
