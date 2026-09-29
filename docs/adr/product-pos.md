# Product / POS ADR

## Status

Accepted — initial Product/POS implementation

## Owner

Conslate — Product + POS

## Context

TillFlow is a multi-tenant POS platform. The Product/POS workstream is responsible for the tenant and POS model, sale flow, validation, idempotent sale creation, and the POS user flow.

The POS service must communicate with the Payments service for payment requests. POS must not call Daraja directly.

---

## 1. Tenant Model

A tenant represents a business using TillFlow.

Each tenant has:

- `id`
- `name`
- `commission_rate`
- `created_at`

Tenant-owned resources are associated with the tenant through `tenant_id`.

---

## 2. Till Model

A till represents a point of sale belonging to a tenant.

Each till has:

- `id`
- `tenant_id`
- `name`
- `created_at`

A till must belong to the tenant associated with the sale.

---

## 3. Attendant Model

An attendant represents a user operating a tenant's till.

Each attendant has:

- `id`
- `tenant_id`
- `name`
- `role`
- `created_at`

The attendant must belong to the same tenant as the sale.

---

## 4. Commission Rate

The tenant stores a commission rate as an integer value.

```text
Tenant
  |
  +-- commission_rate
