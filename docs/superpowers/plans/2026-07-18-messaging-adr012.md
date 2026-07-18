# ADR-012 Messaging (SNS/SQS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two SNS topic + SQS queue + DLQ pairs required by ADR-012 (`notification_events` and `user_events`) to both `dev/` (LocalStack) and `prod/` (real AWS) Terraform roots of `iac-video-processor-infra`, so `video-processor-authentication-api` can publish and `video-processor-users-api`'s new worker / `tech-challenge-notification-service` can consume.

**Architecture:** One new file per environment (`prod/messaging.tf`, `dev/messaging.tf`), each declaring two independent SNS→SQS fan-out pairs: an SQS queue policy grants the topic `sqs:SendMessage` scoped by `aws:SourceArn`, and an `aws_sns_topic_subscription` wires topic to queue. Each queue has a DLQ wired via `redrive_policy`, `maxReceiveCount = 3`. No IAM policies for the publishing/consuming services are created here — per spec section 4.1, "each consumer manages its own access policy" in its own repo via cross-repo `data` lookups by name. This repo only produces the resources and outputs their ARNs. `dev/` mirrors `prod/` exactly (same resource blocks, same file), differing only in the LocalStack provider `endpoints{}` block gaining `sns`/`sqs` entries — same pattern already used for `ec2`/`ecr`/`eks`/`iam`/`sts`/`cloudwatchlogs`.

**Tech Stack:** Terraform `>= 1.11`, `hashicorp/aws ~> 6.54` (no new provider/module — these are native `aws_sns_topic`/`aws_sqs_queue`/`aws_sns_topic_subscription`/`aws_sqs_queue_policy` resources, no registry module exists for this shape), `terraform test` with `mock_provider` for unit-level wiring checks in `prod/tests/`.

**Note on "TDD" for this plan:** same adapted cycle as the rest of this repo's plans (see `docs/superpowers/plans/2026-07-15-infra-implementation.md`) — write the `.tf` file → `terraform validate` → write `terraform test` assertions that check values *we* declare (redrive policy JSON, queue policy JSON, subscription protocol/endpoint references, resource name strings) → run → confirm PASS → commit. These aren't opaque module outputs, so a passing assertion is real evidence the wiring (DLQ arn used in redrive policy, SNS arn used in queue policy condition, topic arn used in subscription) is correct, not just syntactically valid HCL.

## Global Constraints

- Two pairs, two different naming conventions (spec section 4.1 / ADR-012 spec section 2):
  - **Notification pair — project-agnostic name** (no `video-processor-` prefix, because `tech-challenge-notification-service` is a reused general-purpose Lambda whose Terraform already assumes this default name): topic `notification-events-topic-${var.environment}`, queue `notification-events-queue-${var.environment}`, DLQ `notification-events-queue-${var.environment}-dlq`.
  - **User-signup domain-event pair — keeps the `video-processor-` prefix** (project-specific domain event): topic `video-processor-user-events-topic-${var.environment}`, queue `video-processor-user-events-queue-${var.environment}`, DLQ `video-processor-user-events-queue-${var.environment}-dlq`.
- Notification queue `visibility_timeout_seconds = 180` (6x the 30s Lambda consumer timeout). User-events queue `visibility_timeout_seconds = 60` (worker does one idempotent INSERT).
- Both DLQs: no special config beyond the name — `redrive_policy` on the main queue points `deadLetterTargetArn` at the DLQ arn, `maxReceiveCount = 3`.
- Notification subscription has **no** `raw_message_delivery` — `notification-service`'s `ConsumeSQS` expects the full SNS envelope (`{Message, MessageAttributes}`) in the SQS body. Neither pair sets it (both omit the argument, which defaults to `false`/full envelope).
- Both queue policies: `Principal = {Service = "sns.amazonaws.com"}`, `Action = "sqs:SendMessage"`, `Condition = {ArnEquals = {"aws:SourceArn" = <this pair's topic arn>}}` — scoped per-pair, not a shared policy.
- New outputs (both environments): `notification_events_topic_arn`, `user_events_topic_arn`, `user_events_queue_arn` (spec section 4.1, ADR-012 spec section 2 — these three, not more; the DLQ arns and the notification queue arn have no declared consumer yet, so no output for them — YAGNI).
- No IAM resources in this repo for these topics/queues — `sns:Publish`/`sqs:ReceiveMessage` policies live in the consuming services' own `terraform/` (spec section 4.1, last paragraph; section 5 IAM summary).
- Resource naming/tags: standard `Project = "video-processor"`, `Environment = var.environment` tags on the topics (matches existing `vpc.tf`/`eks.tf`/`ecr.tf` tagging convention in both environments). Queues follow the same convention used elsewhere in this repo (no explicit `tags` block is strictly required by the spec's HCL snippets, but add the standard two tags to stay consistent with every other resource in this repo).
- `dev/` gets the exact same two pairs (no prod-only restriction — LocalStack Community has no documented SNS/SQS limitation, unlike its EKS control-plane/IAM gaps; confirmed by cross-repo dependency language in the umbrella spec that doesn't carve out an environment exception). `dev/main.tf`'s provider `endpoints{}` block gains `sns` and `sqs` entries pointing at `http://localhost:4566`, alongside the existing six.

---

## File Structure

```
iac-video-processor-infra/
├── prod/
│   ├── messaging.tf      # NEW — both SNS/SQS/DLQ pairs
│   ├── outputs.tf        # MODIFIED — +3 outputs
│   └── tests/
│       └── infra_unit_test.tftest.hcl   # MODIFIED — +2 run blocks (messaging wiring)
└── dev/
    ├── main.tf            # MODIFIED — provider endpoints{} +sns +sqs
    ├── messaging.tf        # NEW — same two pairs, ${var.environment} = "localstack"
    └── outputs.tf          # MODIFIED — +3 outputs
```

---

### Task 1: `prod/messaging.tf` — both SNS/SQS/DLQ pairs + outputs

**Files:**
- Create: `prod/messaging.tf`
- Modify: `prod/outputs.tf`

**Interfaces:**
- Produces: `aws_sns_topic.notification_events`, `aws_sqs_queue.notification_events`, `aws_sqs_queue.notification_events_dlq`, `aws_sns_topic.user_events`, `aws_sqs_queue.user_events`, `aws_sqs_queue.user_events_dlq` (all consumed by Task 2's test assertions). Outputs `notification_events_topic_arn`, `user_events_topic_arn`, `user_events_queue_arn`.

- [ ] **Step 1: Create `prod/messaging.tf`**

```hcl
resource "aws_sns_topic" "notification_events" {
  name = "notification-events-topic-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "notification_events_dlq" {
  name = "notification-events-queue-${var.environment}-dlq"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "notification_events" {
  name                       = "notification-events-queue-${var.environment}"
  visibility_timeout_seconds = 180 # 6x the 30s consumer Lambda timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notification_events_dlq.arn
    maxReceiveCount      = 3
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "notification_events" {
  topic_arn = aws_sns_topic.notification_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.notification_events.arn
  # No raw_message_delivery — notification-service's ConsumeSQS expects the
  # full SNS envelope ({Message, MessageAttributes}) in the SQS body.
}

resource "aws_sqs_queue_policy" "notification_events" {
  queue_url = aws_sqs_queue.notification_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.notification_events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.notification_events.arn } }
    }]
  })
}

resource "aws_sns_topic" "user_events" {
  name = "video-processor-user-events-topic-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "user_events_dlq" {
  name = "video-processor-user-events-queue-${var.environment}-dlq"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "user_events" {
  name                       = "video-processor-user-events-queue-${var.environment}"
  visibility_timeout_seconds = 60 # worker does a single idempotent INSERT

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.user_events_dlq.arn
    maxReceiveCount      = 3
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "user_events" {
  topic_arn = aws_sns_topic.user_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.user_events.arn
}

resource "aws_sqs_queue_policy" "user_events" {
  queue_url = aws_sqs_queue.user_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.user_events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.user_events.arn } }
    }]
  })
}
```

- [ ] **Step 2: Append the three new outputs to `prod/outputs.tf`**

```hcl
output "notification_events_topic_arn" {
  description = "ARN of the notification-events SNS topic (consumed by video-processor-authentication-api)"
  value       = aws_sns_topic.notification_events.arn
}

output "user_events_topic_arn" {
  description = "ARN of the video-processor-user-events SNS topic (consumed by video-processor-authentication-api)"
  value       = aws_sns_topic.user_events.arn
}

output "user_events_queue_arn" {
  description = "ARN of the video-processor-user-events SQS queue (consumed by video-processor-users-api's worker)"
  value       = aws_sqs_queue.user_events.arn
}
```

- [ ] **Step 3: Validate**

Run: `cd prod && terraform fmt messaging.tf outputs.tf && terraform validate`
Expected: `terraform fmt` may reprint `messaging.tf` (it auto-aligns the `=` inside the `jsonencode({...})` object constructors — this is cosmetic, not a wiring change); `terraform validate` prints `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add prod/messaging.tf prod/outputs.tf
git commit -m "feat(prod): add notification-events and user-events SNS/SQS/DLQ pairs (ADR-012)"
```

---

### Task 2: `prod/tests/infra_unit_test.tftest.hcl` — messaging wiring assertions

**Files:**
- Modify: `prod/tests/infra_unit_test.tftest.hcl`

**Interfaces:**
- Consumes: `aws_sns_topic.notification_events`, `aws_sqs_queue.notification_events`, `aws_sqs_queue.notification_events_dlq`, `aws_sns_topic_subscription.notification_events`, `aws_sqs_queue_policy.notification_events`, `aws_sns_topic.user_events`, `aws_sqs_queue.user_events`, `aws_sqs_queue.user_events_dlq`, `aws_sns_topic_subscription.user_events`, `aws_sqs_queue_policy.user_events` — all from Task 1.

**Post-implementation note:** the `run` blocks below, exactly as written, fail under plain `command = plan` with `Unknown condition value` — `aws_sns_topic.arn`/`aws_sqs_queue.arn` are provider-computed and unknown-until-apply for resources with no prior state, independent of this file's `mock_provider` block (which only supplies `mock_data`, not `mock_resource`, for SNS/SQS). The implementation adds `override_resource { target = ...; values = { arn = "..." }; override_during = plan }` inside each new `run` block (not the shared `mock_provider`) to supply known ARNs for the three resources each block's assertions touch. This was verified (by both the task reviewer and the final branch reviewer, independently) to still catch real wiring regressions via mutation testing — it unblocks evaluation of computed values, it does not short-circuit the assertions.

- [ ] **Step 1: Append two `run` blocks to `prod/tests/infra_unit_test.tftest.hcl`**

Add before the final closing of the file (after the existing `ecr_repository_named_per_environment_convention` run block):

```hcl
run "notification_events_pair_named_and_wired_per_spec" {
  command = plan

  assert {
    condition     = aws_sns_topic.notification_events.name == "notification-events-topic-prod"
    error_message = "Expected the notification SNS topic to be project-agnostic (no video-processor- prefix), per ADR-012"
  }

  assert {
    condition     = aws_sqs_queue.notification_events.name == "notification-events-queue-prod"
    error_message = "Expected the notification SQS queue name to match the notification-events-queue-${var.environment} convention"
  }

  assert {
    condition     = aws_sqs_queue.notification_events_dlq.name == "notification-events-queue-prod-dlq"
    error_message = "Expected the notification DLQ name to be the main queue name with a -dlq suffix"
  }

  assert {
    condition     = aws_sqs_queue.notification_events.visibility_timeout_seconds == 180
    error_message = "Expected the notification queue visibility timeout to be 180s (6x the 30s consumer Lambda timeout)"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.notification_events.redrive_policy).deadLetterTargetArn == aws_sqs_queue.notification_events_dlq.arn
    error_message = "Expected the notification queue's redrive_policy to point at its own DLQ arn, not some other queue"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.notification_events.redrive_policy).maxReceiveCount == 3
    error_message = "Expected maxReceiveCount to be 3 for the notification queue's redrive policy"
  }

  assert {
    condition     = aws_sns_topic_subscription.notification_events.endpoint == aws_sqs_queue.notification_events.arn
    error_message = "Expected the notification SNS subscription to point at the notification SQS queue, not a different queue"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue_policy.notification_events.policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == aws_sns_topic.notification_events.arn
    error_message = "Expected the notification queue policy to scope SendMessage to its own topic's arn via aws:SourceArn"
  }
}

run "user_events_pair_named_and_wired_per_spec" {
  command = plan

  assert {
    condition     = aws_sns_topic.user_events.name == "video-processor-user-events-topic-prod"
    error_message = "Expected the user-events SNS topic to keep the video-processor- prefix (project-specific domain event), per ADR-012"
  }

  assert {
    condition     = aws_sqs_queue.user_events.name == "video-processor-user-events-queue-prod"
    error_message = "Expected the user-events SQS queue name to match the video-processor-user-events-queue-${var.environment} convention"
  }

  assert {
    condition     = aws_sqs_queue.user_events_dlq.name == "video-processor-user-events-queue-prod-dlq"
    error_message = "Expected the user-events DLQ name to be the main queue name with a -dlq suffix"
  }

  assert {
    condition     = aws_sqs_queue.user_events.visibility_timeout_seconds == 60
    error_message = "Expected the user-events queue visibility timeout to be 60s (worker does a single idempotent INSERT)"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.user_events.redrive_policy).deadLetterTargetArn == aws_sqs_queue.user_events_dlq.arn
    error_message = "Expected the user-events queue's redrive_policy to point at its own DLQ arn, not some other queue"
  }

  assert {
    condition     = aws_sns_topic_subscription.user_events.endpoint == aws_sqs_queue.user_events.arn
    error_message = "Expected the user-events SNS subscription to point at the user-events SQS queue, not a different queue"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue_policy.user_events.policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == aws_sns_topic.user_events.arn
    error_message = "Expected the user-events queue policy to scope SendMessage to its own topic's arn via aws:SourceArn"
  }
}
```

- [ ] **Step 2: Run the tests**

Run: `cd prod && terraform test`
Expected: All `run` blocks report `pass`, including the two new ones (`notification_events_pair_named_and_wired_per_spec`, `user_events_pair_named_and_wired_per_spec`). No changes to the pre-existing `mock_provider`/`mock_data` block are needed — SNS/SQS resources have no data-source dependency on the mocked `aws_iam_policy_document`/`aws_partition`/`aws_iam_role`.

- [ ] **Step 3: Commit**

```bash
git add prod/tests/infra_unit_test.tftest.hcl
git commit -m "test(prod): assert messaging wiring for notification-events and user-events pairs"
```

---

### Task 3: `dev/messaging.tf` + LocalStack endpoints + outputs

**Files:**
- Create: `dev/messaging.tf`
- Modify: `dev/main.tf`
- Modify: `dev/outputs.tf`

**Interfaces:**
- Produces: same resource addresses as Task 1 (`aws_sns_topic.notification_events`, etc.), scoped to `dev/`'s own state. Outputs `notification_events_topic_arn`, `user_events_topic_arn`, `user_events_queue_arn`.

- [ ] **Step 1: Add `sns` and `sqs` to `dev/main.tf`'s provider `endpoints{}` block**

In `dev/main.tf`, the `provider "aws"` block's `endpoints {}` currently reads:

```hcl
  endpoints {
    ec2            = "http://localhost:4566"
    ecr            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    cloudwatchlogs = "http://localhost:4566"
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
  }
```

- [ ] **Step 2: Create `dev/messaging.tf`**

Identical content to `prod/messaging.tf` from Task 1, Step 1 (same resource blocks verbatim — `var.environment` defaults to `"localstack"` in `dev/variables.tf`, so names resolve to `notification-events-topic-localstack` etc. at `plan`/`apply` time).

- [ ] **Step 3: Append the three new outputs to `dev/outputs.tf`**

Same three output blocks as Task 1, Step 2, verbatim.

- [ ] **Step 4: Validate**

Run: `cd dev && terraform fmt messaging.tf main.tf outputs.tf && terraform validate`
Expected: `terraform fmt` may reprint `messaging.tf` (same cosmetic `jsonencode` alignment as `prod/`); `terraform validate` prints `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add dev/main.tf dev/messaging.tf dev/outputs.tf
git commit -m "feat(dev): add notification-events and user-events SNS/SQS/DLQ pairs (ADR-012)"
```

---

## Explicitly out of scope for this plan

- Any change to `video-processor-authentication-api`, `video-processor-users-api`, or `tech-challenge-notification-service` — those repos' own IAM policies and application code are out of scope here (spec section 4.1: "each consumer manages its own access policy" in its own repo).
- The `role` column removal from `iac-video-processor-data`'s documented `users` schema — separate repo, separate plan.
- CI pipeline changes — no `.github/workflows/` exists yet in this repo for any resource type (VPC/EKS/ECR included); wiring the pipeline is a pre-existing gap unrelated to ADR-012, not addressed by this plan.
