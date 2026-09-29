# TillFlow G3 Capacity Envelope

## Test environment

- Environment: dev
- AWS Region: eu-west-3
- ECS Cluster: devops-g8-tillflow
- Service under test: devops-g8-pos
- Endpoint: /pos/health
- SLO p95 target: < 500 ms
- Failed request target: < 1%
- Checks target: > 99%
- CPU target: < 70%
- Memory target: < 75%

## Load profiles

### Stepped Baseline

- Requests: 13,150
- Failed requests: 0.000%
- p95 latency: 192.75 ms
- Checks passed: 100.000%
- Peak VUs: 100
- Interrupted iterations: 0
- Result: PASS

### Spike

- Requests: 7,110
- Failed requests: 0.000%
- p95 latency: 189.61 ms
- Checks passed: 100.000%
- Peak VUs: 200
- Interrupted iterations: 0
- Result: PASS

### Soak

- Duration: 16 minutes
- Requests: 15,668
- Failed requests: 0.000%
- p95 latency: 189.13 ms
- Checks passed: 100.000%
- Peak VUs: 20
- Interrupted iterations: 0
- Result: PASS

## Resource observations

CloudWatch ECS metrics for `devops-g8-pos` were inspected during the test period.

- Highest observed CPU maximum: approximately 2.13%
- Required CPU ceiling: < 70%
- Highest observed memory maximum: approximately 4.10%
- Required memory ceiling: < 75%

Both CPU and memory remained substantially below the defined capacity thresholds.

## Capacity conclusion

The tested `/pos/health` workload remained within the defined SLO thresholds through the stepped baseline, 200-VU spike, and >=15-minute soak tests.

No request-level capacity boundary was reached during these tests. The highest tested concurrency was 200 VUs during the spike profile, with 0% request failures and p95 latency below 500 ms.

Resource utilization also remained low, with observed CPU and memory substantially below their defined ceilings. This indicates significant compute headroom for the tested health-check workload.

The results must not be interpreted as the capacity limit of the complete TillFlow money path. The test targeted `/pos/health` and therefore does not establish the maximum sustainable throughput of Sale -> Payments -> M-Pesa processing.

## Bottleneck

No bottleneck was identified within the tested range. The test ceiling, rather than CPU, memory, latency, or request failures, was the limiting factor in determining the observed envelope.

## Caching

Caching before/after comparison is not applicable to this test because the `/pos/health` path does not depend on application caching.

## Evidence

- `k6-stepped-baseline-summary.json`
- `k6-spike-summary.json`
- `k6-soak-summary.json`
- CloudWatch ECS CPUUtilization metrics
- CloudWatch ECS MemoryUtilization metrics
