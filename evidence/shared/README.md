# Shared Evidence — Index

Per the capstone brief, this folder is meant to hold cross-cutting
evidence: k6 results, traces, Grafana export, alerts, scans, Terraform
plan, and restore test proof.

In practice, this evidence was filed under
[`evidence/reliability/`](../reliability/) instead, since it was
produced and owned as part of Reliability + Operations' work. Rather
than duplicate or move those files (which would break the links
already pointing to them from
[`evidence/platform/g0-g3-closure.md`](../platform/g0-g3-closure.md)
and elsewhere), this file exists as a pointer so this folder isn't
empty and undiscoverable.

## Where things actually are

- **k6 load test results** (stepped baseline, spike, 16-minute soak):
  [`evidence/reliability/k6-stepped-baseline-summary.json`](../reliability/k6-stepped-baseline-summary.json),
  [`k6-spike-summary.json`](../reliability/k6-spike-summary.json),
  [`k6-soak-summary.json`](../reliability/k6-soak-summary.json), with
  narrative context in
  [`capacity-envelope.md`](../reliability/capacity-envelope.md)
- **Grafana SLO dashboard evidence**:
  [`evidence/reliability/g3-grafana-slo-runtime.md`](../reliability/g3-grafana-slo-runtime.md)
- **Alerts (CloudWatch → SNS → Slack, fire and recovery)**: documented
  in [`docs/runbook.md`](../../docs/runbook.md) and
  `g3-grafana-slo-runtime.md` above
- **Scans** (Trivy image/IaC, gitleaks): run results referenced in
  [`evidence/platform/g0-g3-closure.md`](../platform/g0-g3-closure.md)
  and `.github/workflows/`
- **Terraform plan**: referenced in
  [`evidence/platform/g1-cicd/README.md`](../platform/g1-cicd/README.md)
- **Restore test**: not yet performed — tracked as an open G4 drill in
  [`docs/production-readiness.md`](../../docs/production-readiness.md)