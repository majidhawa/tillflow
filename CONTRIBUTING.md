# Contributing to TillFlow

## Branching

All work must be completed on a non-`main` branch and submitted through a pull request.

Recommended branch formats:

- `hawa/<scope>`
- `glory/<scope>`
- `consolate/<scope>`

Examples:

- `hawa/g1-networking`
- `glory/payments-daraja-adapter`
- `consolate/pos-sale-flow`

Direct pushes to `main` are not allowed by team policy.

## Commit messages

Use Conventional Commit-style messages:

- `feat:` new functionality
- `fix:` bug fix
- `docs:` documentation
- `test:` tests
- `refactor:` code restructuring without behavior change
- `chore:` repository or maintenance work
- `ci:` CI/CD changes
- `infra:` infrastructure changes

Examples:

- `infra: add g8 VPC baseline`
- `feat: add sale creation endpoint`
- `fix: preserve uncertain payment state on timeout`
- `docs: add payment reconciliation ADR`

Avoid vague messages such as `update`, `changes`, `final`, `stuff`, or `fixes`.

## Pull requests

Every PR must document:

1. What changed
2. Why it changed
3. How it was tested
4. Reproducible verification or evidence
5. Related gate or requirement
6. Reviewer from the agreed cross-review matrix

Review conversations must be resolved before merge.

## Human ownership and AI use

AI tools may assist with research, debugging, drafting, and implementation.

However:

- Every commit and PR must have a human owner.
- The human author must understand and validate submitted changes.
- AI or bot accounts must not author final commits or act as the required human approver.
- AI-generated code must be reviewed and tested before submission.
- Secrets, tokens, credentials, customer data, and other sensitive information must never be committed or submitted to AI tools.

## Review ownership

- Hawa reviews Product + POS.
- Glory reviews Platform + Delivery and Reliability + Operations.
- Consolate reviews Payments + Integrity.

The DRI remains accountable for their owned area even when implementation is collaborative.
