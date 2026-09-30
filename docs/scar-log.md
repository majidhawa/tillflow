# Scar Log

A running record of real incidents during TillFlow's build — what broke,
why, and what fixed it. Kept honest on purpose: this is what actually
happened, not a cleaned-up version of events.

## CI silently not testing Go code

**What happened:** `pr-ci.yml`'s `service-ci` job was written expecting
Node.js projects (`package.json`, `npm ci`, `npm test`). All four
services are Go. Since no `package.json` exists, every Node-specific
step silently skipped rather than failing — lint, typecheck, test, and
the Trivy dependency scan never actually ran against any service's Go
code. Only the Docker build step provided real validation.

**Impact:** discovered while reviewing the CI pipeline, not from a
failure — meaning Go code had been merging without any of its own
tests or scans running for as long as this had been true.

**Status:** flagged; Go-specific CI steps (`go vet`, `go test`, a Go
dependency scanner) still need to be added to `pr-ci.yml` to close this
gap for real.

## Dockerfile only copying named files, breaking on new source files

**What happened:** the payments Dockerfile used
`COPY go.mod main.go ./` — copying `main.go` by name instead of all
`.go` files. The first time a second file (`auth.go`) was added, the
Docker build failed with `undefined: darajaAuth` even though the local
build worked fine, since local `go build .` picks up every file in the
directory automatically.

**Fix:** changed to `COPY go.mod *.go ./` to copy every Go source file.
Recurred a second time when `go.sum` first appeared (once real external
dependencies were added) — same class of bug, fixed by adding `go.sum`
to the same COPY line.

**Lesson:** a Dockerfile that copies files by explicit name is a silent
trap the moment a service grows past its initial file. Worth reviewing
all four services' Dockerfiles for the same pattern.

## Timeout misclassified as decline

**What happened:** the STK Push callback handler originally treated
any non-zero Daraja `ResultCode` as `failed`. Testing against the real
sandbox surfaced `ResultCode 1037` ("No response from user") — a
timeout, not a decline — which was being recorded as `failed` anyway.

**Why it matters:** the sale-payment contract explicitly requires a
timeout to be preserved as `timed_out`/`uncertain`, not treated as a
decline, since the true outcome is unknown until reconciliation
confirms it. Misclassifying a timeout as a failure risks telling an
attendant a sale failed when the customer may actually still be
charged.

**Fix:** replaced the binary success/failure check with an explicit
switch over known Daraja result codes (0 = confirmed, 1037 = timed_out,
1032 = failed, anything else = uncertain).

## OpenTelemetry dependency upgrade silently changed the Go toolchain version

**What happened:** running `go get` for a specific OTel submodule
(`semconv/v1.26.0`) without pinning a version pulled in the *latest*
release of the whole `go.opentelemetry.io/otel` family, which required
Go 1.25+ and silently rewrote `go.mod`'s `go` directive from `1.23` to
`1.25.0`. This didn't fail locally (a newer local Go toolchain
auto-installed to satisfy it), but would have broken the Docker build,
which is pinned to an older Go base image.

**Fix:** re-ran `go get` with every OTel package pinned to the exact
same version already in use (`@v1.30.0`), then explicitly reset the
`go` directive with `go mod edit -go=1.23`.

**Lesson:** an unpinned `go get` on any single package in a
multi-package family (OTel, in this case) can upgrade the whole family
and the language version along with it — always pin the version
explicitly when adding to an existing dependency set.

## AWS SSO session expiring mid-task, causing a false "infrastructure destroyed" scare

**What happened:** while running Terraform against the shared AWS
account via a temporary SSO session, the session token expired
partway through a work session. Subsequent AWS CLI commands silently
fell back to a different, personal AWS account's default credentials
rather than erroring outright. This produced `ClusterNotFoundException`
and `ResourceNotFoundException` errors that looked exactly like the
live ECS cluster and Terraform lock table had been deleted, when in
fact the commands were simply running against the wrong (empty)
account.

**Fix:** re-verified with `aws sts get-caller-identity` — which showed
the personal account, not the shared one — refreshed the SSO session,
and confirmed the real infrastructure was untouched the whole time.

**Lesson:** always check `aws sts get-caller-identity` as the *first*
diagnostic step for any unexpected AWS API error, before assuming
infrastructure itself has changed. A silently-expired session and an
actually-deleted resource produce identical-looking errors.

## Unsynchronized map writes crashing the process under concurrent load

**What happened:** `paymentStore`'s idempotency-key map had no mutex,
unlike `callbackStore` and `payoutStore`, which both correctly used
one. Sequential manual testing throughout the night never surfaced
this, since only one request was ever in flight at a time. Running a
k6 load test at 100 concurrent virtual users against `/payments` (using
the deterministic fake Daraja adapter, `scripts/fake-daraja/`) crashed
the entire process within about 80 seconds:

    fatal error: concurrent map writes
    main.(*paymentStore).put(...)
    	services/payments/stkpush.go:75

This is Go's runtime deliberately killing the process on detecting
unsynchronized concurrent map access, rather than risk silent data
corruption.

**Fix:** added the same `sync.Mutex` pattern already used by
`callbackStore` and `payoutStore` to `paymentStore`'s `get` and `put`
methods.

**Verification:** re-ran the identical 100-VU, 60-second load test
after the fix — 7,273 requests, 0% failures, p95 4.78ms, no crash.

**Lesson:** a correctness bug in shared in-memory state can be
completely invisible under any amount of sequential or low-concurrency
testing, and only appears under genuine concurrent load. This is
exactly why the capstone brief requires k6 load testing against a
deterministic fake adapter — this bug would have shipped to any real
concurrent traffic otherwise, sequential testing gave zero signal of
it, however much of it was done.