# ADR-013 jwt-signing-key Secret Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision the `jwt-signing-key-${var.environment}` secret in AWS Secrets Manager, in both `dev/` (LocalStack) and `prod/` (real AWS) Terraform roots of `iac-video-processor-infra`, so `video-processor-authentication-api` (signs), `video-processor-authorizer`, and `video-processor-users-api` (both validate) have a shared secret to look up cross-repo.

**Architecture:** One new file per environment (`prod/secrets.tf`, `dev/secrets.tf`), each declaring a `random_password` (64 chars, generated once, stored in Terraform state — same accepted risk as the existing `random_password.seed_admin` pattern documented in `video-processor-authentication-api`'s spec) feeding an `aws_secretsmanager_secret` + `aws_secretsmanager_secret_version` pair. No IAM resources here — each of the three consuming repos owns its own `secretsmanager:GetSecretValue` policy, scoped to this secret's ARN via `data "aws_secretsmanager_secret"` lookup by name (same cross-repo pattern already used for the SNS topics in `messaging.tf`). `dev/` mirrors `prod/` exactly (same resource blocks), differing only in the LocalStack provider `endpoints{}` block gaining a `secretsmanager` entry (same pattern already used for `sns`/`sqs`/`ec2`/etc.) and in `required_providers` needing the `random` provider added alongside `aws`.

**Tech Stack:** Terraform `>= 1.11`, `hashicorp/aws ~> 6.54` (verified current: registry latest is `6.55.0`, compatible with this pin — checked via the Terraform MCP `get_latest_provider_version`), `hashicorp/random ~> 3.9` (new provider for this repo; registry latest `3.9.0` — checked via Terraform MCP `search_providers`), `terraform test` with `mock_provider`/`override_resource` for unit-level wiring checks in `prod/tests/`.

**Note on "TDD" for this plan:** same adapted cycle as the rest of this repo's plans (see `docs/superpowers/plans/2026-07-15-infra-implementation.md`, `docs/superpowers/plans/2026-07-18-messaging-adr012.md`) — write the `.tf` file → `terraform validate` → write `terraform test` assertions that check values *we* declare (secret name string, secret version pointing at the generated password, not a hardcoded string) → run → confirm PASS → commit.

## Global Constraints

- Secret name: `jwt-signing-key-${var.environment}` (ADR-013 decision — diverges from the literal `jwt-signing-key` text in the three consumer specs, but matches the naming convention used by every other resource in this repo).
- `random_password`: `length = 64`, `special = true` — same shape as `random_password.seed_admin` in `video-processor-authentication-api`'s spec (section 9.3).
- **Accepted risk** (same note as `seed_admin`): the generated value is stored in plaintext in the Terraform state. Acceptable only for this hackathon/demo environment.
- No `aws_iam_*` resources in this repo for this secret — each consumer (`authentication-api`, `authorizer`, `users-api`) manages its own `secretsmanager:GetSecretValue` policy in its own repo, scoped to this secret's ARN.
- New outputs (both environments): `jwt_signing_key_secret_arn`, `jwt_signing_key_secret_name`.
- Tags: `Project = "video-processor"`, `Environment = var.environment` — same convention as every other resource in this repo.
- Tests only in `prod/tests/` — this repo's `dev/` has no `.tftest.hcl` today; that asymmetry is intentional (LocalStack `terraform apply` already serves as `dev/`'s validation) and this plan doesn't introduce a new pattern.

---

## File Structure

```
iac-video-processor-infra/
├── prod/
│   ├── secrets.tf      # NEW — random_password + aws_secretsmanager_secret + secret_version
│   ├── main.tf         # MODIFIED — +random provider in required_providers
│   ├── outputs.tf      # MODIFIED — +2 outputs
│   └── tests/
│       └── infra_unit_test.tftest.hcl   # MODIFIED — +1 run block
└── dev/
    ├── main.tf          # MODIFIED — +random provider, +secretsmanager endpoint
    ├── secrets.tf         # NEW — identical resource blocks to prod/
    └── outputs.tf         # MODIFIED — +2 outputs
```

---

### Task 1: `prod/secrets.tf` — secret + random_password + outputs

**Files:**
- Create: `prod/secrets.tf`
- Modify: `prod/main.tf:1-16` (required_providers block)
- Modify: `prod/outputs.tf`

**Interfaces:**
- Produces: `random_password.jwt_signing_key`, `aws_secretsmanager_secret.jwt_signing_key`, `aws_secretsmanager_secret_version.jwt_signing_key` (all consumed by Task 2's test assertions). Outputs `jwt_signing_key_secret_arn`, `jwt_signing_key_secret_name`.

- [ ] **Step 1: Add the `random` provider to `prod/main.tf`'s `required_providers` block**

`prod/main.tf` currently starts with:

```hcl
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }
}
```

Replace the `required_providers` block with:

```hcl
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
```

- [ ] **Step 2: Create `prod/secrets.tf`**

```hcl
resource "random_password" "jwt_signing_key" {
  length  = 64
  special = true
}

resource "aws_secretsmanager_secret" "jwt_signing_key" {
  name = "jwt-signing-key-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "jwt_signing_key" {
  secret_id     = aws_secretsmanager_secret.jwt_signing_key.id
  secret_string = random_password.jwt_signing_key.result
}
```

- [ ] **Step 3: Append the two new outputs to `prod/outputs.tf`**

```hcl
output "jwt_signing_key_secret_arn" {
  description = "ARN of the jwt-signing-key secret (shared between authentication-api, authorizer, and users-api)"
  value       = aws_secretsmanager_secret.jwt_signing_key.arn
}

output "jwt_signing_key_secret_name" {
  description = "Name of the jwt-signing-key secret, for cross-repo lookup via data.aws_secretsmanager_secret"
  value       = aws_secretsmanager_secret.jwt_signing_key.name
}
```

- [ ] **Step 4: Validate**

Run: `cd prod && terraform init -upgrade && terraform fmt secrets.tf main.tf outputs.tf && terraform validate`
Expected: `terraform init -upgrade` downloads the new `hashicorp/random` provider; `terraform validate` prints `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add prod/secrets.tf prod/main.tf prod/outputs.tf prod/.terraform.lock.hcl
git commit -m "feat(prod): provision jwt-signing-key secret (ADR-013)"
```

---

### Task 2: `prod/tests/infra_unit_test.tftest.hcl` — secret wiring assertions

**Files:**
- Modify: `prod/tests/infra_unit_test.tftest.hcl`

**Interfaces:**
- Consumes: `random_password.jwt_signing_key`, `aws_secretsmanager_secret.jwt_signing_key`, `aws_secretsmanager_secret_version.jwt_signing_key` — all from Task 1.

**Note on `override_resource`:** `random_password.result` is a Read-Only, apply-time-computed attribute (confirmed via the Terraform MCP provider docs) — under plain `command = plan` it's unknown, and comparing two unknown values with `==` makes the assert condition itself unknown, which `terraform test` rejects. Following the exact pattern already used in this file for `aws_sns_topic`/`aws_sqs_queue` ARNs, this run block uses `override_resource { target = random_password.jwt_signing_key; override_during = plan }` to supply a known `result` value scoped to this run block only.

- [ ] **Step 1: Append one `run` block to `prod/tests/infra_unit_test.tftest.hcl`**

Add after the last existing `run` block (`user_events_pair_named_and_wired_per_spec`):

```hcl
run "jwt_signing_key_secret_named_and_wired_per_spec" {
  command = plan

  override_resource {
    target = random_password.jwt_signing_key
    values = {
      result = "mock-generated-password-value"
    }
    override_during = plan
  }

  assert {
    condition     = aws_secretsmanager_secret.jwt_signing_key.name == "jwt-signing-key-prod"
    error_message = "Expected the JWT signing key secret name to follow the jwt-signing-key-${var.environment} convention"
  }

  assert {
    condition     = random_password.jwt_signing_key.length == 64
    error_message = "Expected the generated JWT signing key to be 64 characters long"
  }

  assert {
    condition     = aws_secretsmanager_secret_version.jwt_signing_key.secret_string == "mock-generated-password-value"
    error_message = "Expected the secret version to store the random_password-generated value, not a hardcoded string"
  }
}
```

- [ ] **Step 2: Run the tests**

Run: `cd prod && terraform test`
Expected: All `run` blocks report `pass`, including the new `jwt_signing_key_secret_named_and_wired_per_spec`.

- [ ] **Step 3: Commit**

```bash
git add prod/tests/infra_unit_test.tftest.hcl
git commit -m "test(prod): assert jwt-signing-key secret naming and wiring"
```

---

### Task 3: `dev/secrets.tf` + LocalStack endpoint + outputs

**Files:**
- Create: `dev/secrets.tf`
- Modify: `dev/main.tf`
- Modify: `dev/outputs.tf`

**Interfaces:**
- Produces: same resource addresses as Task 1, scoped to `dev/`'s own state. Outputs `jwt_signing_key_secret_arn`, `jwt_signing_key_secret_name`.

- [ ] **Step 1: Add the `random` provider to `dev/main.tf`'s `required_providers` block**

Same edit as Task 1, Step 1, applied to `dev/main.tf`'s `required_providers` block.

- [ ] **Step 2: Add `secretsmanager` to `dev/main.tf`'s provider `endpoints{}` block**

`dev/main.tf`'s `provider "aws"` block's `endpoints {}` currently reads:

```hcl
  endpoints {
    ec2            = "http://localhost:4566"
    ecr            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    cloudwatchlogs = "http://localhost:4566"
    sns            = "http://localhost:4566"
    sqs            = "http://localhost:4566"
  }
```

Replace it with:

```hcl
  endpoints {
    ec2            = "http://localhost:4566"
    ecr            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    cloudwatchlogs = "http://localhost:4566"
    sns            = "http://localhost:4566"
    sqs            = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
  }
```

- [ ] **Step 3: Create `dev/secrets.tf`**

Identical content to `prod/secrets.tf` from Task 1, Step 2 (same resource blocks verbatim — `var.environment` defaults to `"localstack"` in `dev/variables.tf`, so the secret name resolves to `jwt-signing-key-localstack` at `plan`/`apply` time).

- [ ] **Step 4: Append the two new outputs to `dev/outputs.tf`**

Same two output blocks as Task 1, Step 3, verbatim.

- [ ] **Step 5: Validate**

Run: `cd dev && terraform init -upgrade && terraform fmt secrets.tf main.tf outputs.tf && terraform validate`
Expected: `terraform init -upgrade` downloads the new `hashicorp/random` provider; `terraform validate` prints `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add dev/secrets.tf dev/main.tf dev/outputs.tf dev/.terraform.lock.hcl
git commit -m "feat(dev): provision jwt-signing-key secret (ADR-013)"
```

---

## Explicitly out of scope for this plan

- The two gateway routes (`POST /auth/signup`, `GET /auth/verify`) — separate repo (`iac-video-processor-gateway`), separate plan (`docs/superpowers/plans/2026-07-18-gateway-auth-routes.md` in that repo).
- Any `secretsmanager:GetSecretValue` IAM policy in `video-processor-authentication-api`, `video-processor-authorizer`, or `video-processor-users-api` — each of those repos owns its own policy; out of scope here.
- Secret rotation — open question, see ADR-013 spec section 6.
- Any `terraform apply` against real AWS or LocalStack — this plan only validates and tests locally; applying is a deploy-time concern outside this plan's scope.
