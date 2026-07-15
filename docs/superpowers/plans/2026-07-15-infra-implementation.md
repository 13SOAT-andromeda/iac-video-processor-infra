# iac-video-processor-infra Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision the shared network and compute infrastructure for the video-processor auth/users domain — VPC, EKS cluster + node group, and per-service ECR repositories — in both `dev/` (LocalStack, mocked) and `prod/` (real AWS) environments, plus the centralized `Ingress` manifest and the CI pipeline that installs the AWS Load Balancer Controller and applies it.

**Architecture:** Two independent Terraform root configurations (`dev/`, `prod/`), each calling three registry modules (`terraform-aws-modules/vpc/aws`, `terraform-aws-modules/eks/aws`, `terraform-aws-modules/ecr/aws`) once. `prod/` uses the AWS Academy `LabRole` (via `data "aws_iam_role"`) for both the EKS cluster and node group IAM roles — the module's default role creation is explicitly disabled (`create_iam_role = false`) because the Academy environment lacks `iam:CreateRole`. `dev/` has no `LabRole` (LocalStack has no such role), so it leaves the module's IAM role creation on its default (`create_iam_role = true`). A single `k8s/ingress.yaml` (applied only against `prod/`, via CI) centralizes all HTTP routing to services in the cluster behind one shared internal ALB. The CI pipeline (`.github/workflows/infra-pipeline.yml`) runs `terraform` for `prod/` and, after `apply`, installs the AWS Load Balancer Controller via Helm and applies the `Ingress`.

**Tech Stack:** Terraform `>= 1.11` (required for S3 backend native locking, `use_lockfile`), `hashicorp/aws ~> 6.54`, `terraform-aws-modules/vpc/aws ~> 6.6`, `terraform-aws-modules/eks/aws ~> 21.24`, `terraform-aws-modules/ecr/aws ~> 3.2`, `terraform test` with `mock_provider` for unit-level wiring checks, `tflocal`/LocalStack for the `dev/` smoke test.

**Note on "TDD" for this plan:** same adapted cycle as `iac-video-processor-gateway`'s plan — write the `.tf` file → `terraform validate` → for the task with real wiring logic (Task 4), write a `terraform test` file with `mock_provider` assertions *before* trusting the wiring, run it, confirm PASS → commit. Assertions in Task 4 check values we ourselves declare in `locals`/resource arguments (not the registry modules' opaque computed outputs), so a passing test is actually evidence the wiring is correct, not just syntactically valid HCL.

## Global Constraints

- Terraform `>= 1.11` (S3 backend `use_lockfile` native locking is GA at 1.11 — spec section 3.1); provider `hashicorp/aws ~> 6.54`; modules `terraform-aws-modules/vpc/aws ~> 6.6`, `terraform-aws-modules/eks/aws ~> 21.24`, `terraform-aws-modules/ecr/aws ~> 3.2` (spec section 2). This repo does **not** instantiate `terraform-aws-modules/lambda/aws` — that module is instantiated by each Lambda service repo's own `terraform/` folder (spec section 7), not here.
- Folder structure: `dev/` (LocalStack, `tflocal`) + `prod/` (real AWS, S3 backend, key `video-processor-infra/terraform.tfstate`, `use_lockfile = true`) (spec section 3, 3.1).
- VPC tag contract (fixed, consumed by other repos — **not** the per-environment naming convention below): `Name = video-processor-vpc` in `prod/`, `Name = video-processor-vpc-local` in `dev/` (spec section 4). CIDR `10.0.0.0/16`, 2 AZs (`us-east-1a`, `us-east-1b`), 1 shared NAT Gateway (not one per AZ).
- Per-environment naming convention for everything else (EKS cluster, ECR repos — introduced in this plan, not a pre-existing external contract): `video-processor-eks-${var.environment}`, `video-processor-users-api-${var.environment}` (spec section 5).
- EKS: Kubernetes `1.30` (module variable is named `kubernetes_version`, not `cluster_version` — renamed in this module major version), node group `t3.medium`, `desired_size = 1`/`min_size = 1`/`max_size = 2`, `ami_type = "AL2023_x86_64_STANDARD"` (spec section 5, 9).
- IAM (`prod/` only): `create_iam_role = false` + `iam_role_arn = data.aws_iam_role.lab_role.arn`, set identically at both the cluster level and inside the `eks_managed_node_groups` map entry (confirmed field name via module source — spec section 5). `enable_irsa = false`. `dev/` has no `LabRole` — leaves `create_iam_role` on the module default (`true`) at both levels (spec section 3.2, 5).
- No cluster secrets encryption: `encryption_config = null` (not just `create_kms_key = false` — see Task 3 note; the module's `encryption_config` variable defaults to `{}`, which is non-null and therefore still enables the encryption block even with no KMS key, which would fail).
- `endpoint_public_access = true` (must be set explicitly — this module version defaults it to `false`, unlike the old hand-rolled module; GitHub Actions runners and local `kubectl`/`helm` reach the cluster over the public endpoint, matching `iac-tech-challenge-infra`'s behavior). `endpoint_private_access = true`. `enable_cluster_creator_admin_permissions = true` (so the identity that ran `terraform apply` can immediately run `kubectl`/`helm` without extra `aws-auth` editing).
- ECR: one repository per containerized service (`video-processor-users-api-${var.environment}` this phase), lifecycle policy "keep last 10 images, expire the rest" (spec section 4, replicates `iac-tech-challenge-infra/modules/ecr`).
- `k8s/ingress.yaml`: single centralized `Ingress`, `scheme: internal`, tag `video-processor/alb=unified` via annotation, only path this phase is `/users` → `video-processor-users-api-svc:80` (spec section 6.1). Applied only in the `prod/` CI pipeline — LocalStack Community has no real Kubernetes control plane to apply it against (spec section 3.2, 6).
- Resource/tag naming prefix: `video-processor-*`; standard tags `Project = "video-processor"`, `Environment = ${var.environment}` (umbrella spec section 7).

---

## File Structure

```
iac-video-processor-infra/
├── .gitignore
├── k8s/
│   └── ingress.yaml
├── .github/
│   └── workflows/
│       └── infra-pipeline.yml
├── prod/
│   ├── main.tf          # terraform block (backend s3, use_lockfile), provider, LabRole data source, shared locals
│   ├── variables.tf     # environment, region
│   ├── vpc.tf           # module "vpc"
│   ├── eks.tf           # module "eks" (cluster + node group, LabRole IAM)
│   ├── ecr.tf           # module "ecr_users_api"
│   ├── outputs.tf       # vpc_id, cluster_name, cluster_endpoint, ecr repository url
│   └── tests/
│       └── infra_unit_test.tftest.hcl
└── dev/
    ├── main.tf          # terraform block (backend s3, LocalStack endpoints), provider (LocalStack), shared locals
    ├── variables.tf
    ├── vpc.tf
    ├── eks.tf           # same module call, no LabRole (module default create_iam_role = true)
    ├── ecr.tf
    └── outputs.tf
```

---

### Task 1: `.gitignore` + `prod/` skeleton (terraform block, backend, provider, variables, LabRole)

**Files:**
- Create: `.gitignore`
- Create: `prod/variables.tf`
- Create: `prod/main.tf`

**Interfaces:**
- Produces: `var.environment` (string, default `"prod"`), `var.region` (string, default `"us-east-1"`), `data.aws_iam_role.lab_role` (used by Task 3), `local.cluster_name` (used by Tasks 2 and 3) — all consumed by later tasks in `prod/`.

- [ ] **Step 1: Create `.gitignore`**

```
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
terraform.tfvars
terraform.tfvars.json
*.tfplan
.terraform.lock.hcl

# local development
.aws-sam

# Agents
.claude/
```

- [ ] **Step 2: Create `prod/variables.tf`**

```hcl
variable "environment" {
  description = "Environment name (used in resource naming/tags)"
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
```

- [ ] **Step 3: Create `prod/main.tf`**

```hcl
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }

  backend "s3" {
    key          = "video-processor-infra/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Terraform   = "true"
      Environment = var.environment
      Project     = "video-processor"
    }
  }
}

data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

locals {
  # Fixed cross-repo contract (spec section 4) — NOT the per-environment
  # naming convention used below for the cluster/ECR repo. iac-video-processor-data
  # and iac-video-processor-gateway look this VPC up by this exact tag value.
  vpc_name = "video-processor-vpc"

  cluster_name = "video-processor-eks-${var.environment}"
}
```

- [ ] **Step 4: Validate**

Run: `cd prod && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add .gitignore prod/variables.tf prod/main.tf
git commit -m "chore: bootstrap prod/ terraform skeleton for infra (backend, provider, LabRole)"
```

---

### Task 2: `prod/vpc.tf` — VPC, subnets, NAT Gateway

**Files:**
- Create: `prod/vpc.tf`

**Interfaces:**
- Consumes: `var.environment` (Task 1, for tags), `local.vpc_name`, `local.cluster_name` (Task 1, for subnet auto-discovery tags).
- Produces: `module.vpc` (outputs used by Task 3: `vpc_id`, `private_subnets`) — consumed by `prod/eks.tf`.

- [ ] **Step 1: Write `prod/vpc.tf`**

```hcl
locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = ["us-east-1a", "us-east-1b"]

  # Mirrors iac-tech-challenge-infra/modules/vpc/main.tf's cidrsubnet offsets:
  # private subnets get the low block, public subnets are offset by +4.
  private_subnet_cidrs = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, i)]
  public_subnet_cidrs  = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, i + 4)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.vpc_name
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnet_cidrs
  public_subnets  = local.public_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = true

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                     = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
```

- [ ] **Step 2: Validate**

Run: `cd prod && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add prod/vpc.tf
git commit -m "feat: add prod VPC (2 AZs, 1 shared NAT Gateway, ALB/EKS subnet tags)"
```

---

### Task 3: `prod/eks.tf` — EKS cluster + node group, LabRole IAM

**Files:**
- Create: `prod/eks.tf`

**Interfaces:**
- Consumes: `module.vpc.vpc_id`, `module.vpc.private_subnets` (Task 2), `data.aws_iam_role.lab_role` and `local.cluster_name` (Task 1).
- Produces: `module.eks` (outputs used by Task 6/pipeline: `cluster_name`, `cluster_endpoint`) — consumed by `prod/outputs.tf` (Task 4).

- [ ] **Step 1: Write `prod/eks.tf`**

```hcl
locals {
  # Kept as its own local (rather than inlined in the module call) so the
  # unit test in Task 4 can assert on these values directly — the registry
  # module's own outputs don't re-expose per-node-group sizing inputs.
  node_group_config = {
    users = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = 1
      max_size     = 2
      desired_size = 1

      create_iam_role = false
      iam_role_arn    = data.aws_iam_role.lab_role.arn
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = local.cluster_name
  kubernetes_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access                  = true
  endpoint_private_access                 = true
  enable_cluster_creator_admin_permissions = true

  # AWS Academy: reuse LabRole, module cannot create IAM roles (no iam:CreateRole).
  create_iam_role = false
  iam_role_arn    = data.aws_iam_role.lab_role.arn

  enable_irsa = false

  # create_kms_key = false alone is not enough: encryption_config defaults to
  # {} (non-null), which still enables the cluster's encryption_config block
  # and would try to use a KMS key that doesn't exist. Setting it to null
  # disables the block entirely.
  create_kms_key    = false
  encryption_config = null

  eks_managed_node_groups = local.node_group_config

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
```

- [ ] **Step 2: Validate**

Run: `cd prod && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add prod/eks.tf
git commit -m "feat: add prod EKS cluster + node group wired to LabRole"
```

---

### Task 4: `prod/ecr.tf`, `prod/outputs.tf`, unit test

**Files:**
- Create: `prod/ecr.tf`
- Create: `prod/outputs.tf`
- Create: `prod/tests/infra_unit_test.tftest.hcl`

**Interfaces:**
- Consumes: `module.eks`, `module.vpc` (Tasks 2, 3), `var.environment` (Task 1).
- Produces: `output.vpc_id`, `output.cluster_name`, `output.cluster_endpoint`, `output.users_api_ecr_repository_url` — leaf of this root module, read by other repos/teams out of band (no other Terraform config in this repo consumes them).

- [ ] **Step 1: Write `prod/ecr.tf`**

```hcl
module "ecr_users_api" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.2"

  repository_name = "video-processor-users-api-${var.environment}"

  repository_image_tag_mutability = "MUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
```

- [ ] **Step 2: Create `prod/outputs.tf`**

```hcl
output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "The EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "users_api_ecr_repository_url" {
  description = "The ECR repository URL for video-processor-users-api"
  value       = module.ecr_users_api.repository_url
}
```

- [ ] **Step 3: Validate and initialize**

Run: `cd prod && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Write the unit test — `prod/tests/infra_unit_test.tftest.hcl`**

```hcl
mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/LabRole"
      name = "LabRole"
    }
  }
}

run "vpc_has_two_azs_and_correct_cidr" {
  command = plan

  assert {
    condition     = local.vpc_cidr == "10.0.0.0/16"
    error_message = "Expected VPC CIDR to be 10.0.0.0/16"
  }

  assert {
    condition     = length(local.azs) == 2
    error_message = "Expected exactly 2 AZs (us-east-1a, us-east-1b)"
  }

  assert {
    condition     = length(local.private_subnet_cidrs) == 2 && length(local.public_subnet_cidrs) == 2
    error_message = "Expected 2 private and 2 public subnet CIDRs (one pair per AZ)"
  }
}

run "vpc_uses_single_shared_nat_gateway" {
  command = plan

  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "Expected exactly 1 NAT Gateway (single_nat_gateway = true), not one per AZ"
  }
}

run "cluster_reuses_lab_role_not_a_new_role" {
  command = plan

  assert {
    condition     = local.cluster_name == "video-processor-eks-prod"
    error_message = "Expected cluster name to be video-processor-eks-prod (default environment)"
  }
}

run "node_group_sizing_matches_spec" {
  command = plan

  assert {
    condition     = local.node_group_config.users.instance_types == ["t3.medium"]
    error_message = "Expected the users node group to run on t3.medium"
  }

  assert {
    condition = (
      local.node_group_config.users.min_size == 1 &&
      local.node_group_config.users.max_size == 2 &&
      local.node_group_config.users.desired_size == 1
    )
    error_message = "Expected the users node group to be sized min=1/max=2/desired=1"
  }
}

run "ecr_repository_named_per_environment_convention" {
  command = plan

  assert {
    condition     = module.ecr_users_api.repository_name == "video-processor-users-api-prod"
    error_message = "Expected ECR repository name to follow the video-processor-users-api-${var.environment} convention"
  }
}
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `cd prod && terraform test`
Expected: All 5 `run` blocks report `pass`, final line `Success! 5 passed, 0 failed.` This plan is significantly larger than the gateway's (VPC + EKS + ECR vs. just an HTTP API), so `terraform init`/`terraform test` will take noticeably longer to download and mock-plan the EKS module's submodules — this is expected, not a hang.

If any assertion fails, the wiring in `prod/vpc.tf`/`prod/eks.tf`/`prod/ecr.tf` is wrong — fix those files, not the test.

- [ ] **Step 6: Commit**

```bash
git add prod/ecr.tf prod/outputs.tf prod/tests/infra_unit_test.tftest.hcl
git commit -m "feat: add prod ECR repo for users-api, outputs, and unit test"
```

---

### Task 5: `dev/` — LocalStack environment

**Files:**
- Create: `dev/variables.tf`
- Create: `dev/main.tf`
- Create: `dev/vpc.tf`
- Create: `dev/eks.tf`
- Create: `dev/ecr.tf`
- Create: `dev/outputs.tf`

**Interfaces:**
- Consumes: nothing from `prod/` (fully independent root module/state, same pattern as `iac-video-processor-gateway/dev/` vs `prod/`).
- Produces: `output.vpc_id`, `output.cluster_name`, `output.users_api_ecr_repository_url` — used only for manual smoke testing against `tflocal`.

- [ ] **Step 1: Create `dev/variables.tf`**

```hcl
variable "environment" {
  description = "Environment name (used in resource naming/tags)"
  type        = string
  default     = "localstack"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
```

- [ ] **Step 2: Create `dev/main.tf`**

```hcl
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }

  backend "s3" {
    bucket = "video-processor-bucket-andromeda-local"
    key    = "video-processor-infra/terraform.tfstate"
    region = "us-east-1"
    endpoints = {
      s3       = "http://localhost:4566"
      iam      = "http://localhost:4566"
      sts      = "http://localhost:4566"
      dynamodb = "http://localhost:4566"
    }
    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = false
    use_path_style              = true
  }
}

provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = false
  s3_use_path_style           = true

  endpoints {
    ec2            = "http://localhost:4566"
    ecr            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    cloudwatchlogs = "http://localhost:4566"
  }

  default_tags {
    tags = {
      Terraform   = "true"
      Environment = var.environment
      Project     = "video-processor"
    }
  }
}

locals {
  # Fixed cross-repo contract (spec section 4) — iac-video-processor-gateway's
  # dev/data.tf already filters on this exact value.
  vpc_name = "video-processor-vpc-local"

  cluster_name = "video-processor-eks-${var.environment}"
}
```

- [ ] **Step 3: Create `dev/vpc.tf`**

```hcl
locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = ["us-east-1a", "us-east-1b"]

  private_subnet_cidrs = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, i)]
  public_subnet_cidrs  = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, i + 4)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.vpc_name
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnet_cidrs
  public_subnets  = local.public_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = true

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                     = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
```

- [ ] **Step 4: Create `dev/eks.tf`**

```hcl
locals {
  # No LabRole in LocalStack — omits create_iam_role/iam_role_arn so the
  # module falls back to its default (create_iam_role = true), unlike
  # prod/eks.tf which pins these to LabRole.
  node_group_config = {
    users = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = local.cluster_name
  kubernetes_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access                  = true
  endpoint_private_access                 = true
  enable_cluster_creator_admin_permissions = true

  enable_irsa = false

  create_kms_key    = false
  encryption_config = null

  eks_managed_node_groups = local.node_group_config

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
```

- [ ] **Step 5: Create `dev/ecr.tf`**

```hcl
module "ecr_users_api" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.2"

  repository_name = "video-processor-users-api-${var.environment}"

  repository_image_tag_mutability = "MUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}
```

- [ ] **Step 6: Create `dev/outputs.tf`**

```hcl
output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "users_api_ecr_repository_url" {
  description = "The ECR repository URL for video-processor-users-api"
  value       = module.ecr_users_api.repository_url
}
```

- [ ] **Step 7: Validate**

Run: `cd dev && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 8: Smoke test against LocalStack (manual, requires LocalStack running)**

Run:
```bash
localstack start -d
cd dev
tflocal init
tflocal plan
```
Expected: `tflocal plan` completes without error and shows the VPC, EKS cluster/node group (LocalStack-mocked, no real control plane — see spec section 3.2), and ECR repository to be created. LocalStack Community mocks the EKS API surface enough for `plan`/`apply` to succeed; it does not run a functional Kubernetes control plane.

- [ ] **Step 9: Commit**

```bash
git add dev/
git commit -m "feat: add dev/ LocalStack environment (VPC, EKS mock, ECR)"
```

---

### Task 6: `k8s/ingress.yaml` — centralized Ingress

**Files:**
- Create: `k8s/ingress.yaml`

**Interfaces:**
- Consumes: nothing from Terraform (applied via `kubectl`, not `terraform apply` — spec section 6).
- Produces: the shared ALB (via the AWS Load Balancer Controller, installed in Task 7) — discovered by `iac-video-processor-gateway` via `data.aws_lb` filtering on the `video-processor/alb=unified` tag set by this manifest's annotation.

- [ ] **Step 1: Write `k8s/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: video-processor-ingress
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/tags: video-processor/alb=unified
    alb.ingress.kubernetes.io/healthcheck-path: /health
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /users
            pathType: Prefix
            backend:
              service:
                name: video-processor-users-api-svc
                port:
                  number: 80
```

- [ ] **Step 2: Validate the manifest is well-formed YAML**

Run: `python3 -c "import yaml, sys; yaml.safe_load(open('k8s/ingress.yaml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add k8s/ingress.yaml
git commit -m "feat: add centralized Ingress manifest for the shared ALB"
```

---

### Task 7: `.github/workflows/infra-pipeline.yml` — CI pipeline

**Files:**
- Create: `.github/workflows/infra-pipeline.yml`

**Interfaces:**
- Consumes: `prod/` Terraform config (Tasks 1-4), `k8s/ingress.yaml` (Task 6).
- Produces: nothing consumed by other tasks in this repo — this is the operational entry point other teams/CI use to actually provision the infra.

- [ ] **Step 1: Write `.github/workflows/infra-pipeline.yml`**

```yaml
name: IAC Pipeline

on:
  pull_request:
    branches:
      - develop
      - 'release/*'
      - main
  push:
    branches:
      - main

jobs:
  terraform-ci:
    name: "Terraform CI"
    if: github.event_name == 'pull_request' && (github.base_ref == 'develop' || startsWith(github.base_ref, 'release/'))
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: prod
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.11"

      - name: Terraform Format
        id: fmt
        run: terraform fmt -check
        continue-on-error: true

      - name: Terraform Init
        run: terraform init -backend=false

      - name: Terraform Validate
        id: validate
        run: terraform validate

  terraform-plan:
    name: "Terraform Plan"
    if: github.event_name == 'pull_request' && github.base_ref == 'main'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
    defaults:
      run:
        working-directory: prod
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_SESSION_TOKEN: ${{ secrets.AWS_SESSION_TOKEN }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      AWS_S3_TF_STATE_BUCKET_NAME: ${{ secrets.AWS_S3_TF_STATE_BUCKET_NAME }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.11"

      - name: Bootstrap S3 Backend
        run: |
          if ! aws s3 ls "s3://$AWS_S3_TF_STATE_BUCKET_NAME" > /dev/null 2>&1; then
            echo "State Bucket does not exist. Creating..."
            aws s3 mb s3://$AWS_S3_TF_STATE_BUCKET_NAME --region $AWS_REGION
            echo "Waiting for bucket propagation..."
            sleep 15
          else
            echo "State Bucket already exists."
          fi

      - name: Terraform Init
        id: init
        run: terraform init -input=false -reconfigure -backend-config="bucket=$AWS_S3_TF_STATE_BUCKET_NAME"

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -input=false
        continue-on-error: true

      - uses: actions/github-script@v7
        if: github.event_name == 'pull_request'
        env:
          PLAN: "terraform\n${{ steps.plan.outputs.stdout }}"
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const output = `#### Terraform Plan 📖 \`${{ steps.plan.outcome }}\`

            <details><summary>Show Plan Summary</summary>

            \`\`\`${process.env.PLAN}\`\`\`

            </details>

            *Pushed by: @${{ github.actor }}, Action: \`${{ github.event_name }}\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

  terraform-apply:
    name: "Terraform Apply"
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: prod
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_SESSION_TOKEN: ${{ secrets.AWS_SESSION_TOKEN }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      AWS_S3_TF_STATE_BUCKET_NAME: ${{ secrets.AWS_S3_TF_STATE_BUCKET_NAME }}
    outputs:
      cluster_name: ${{ steps.cluster_name.outputs.value }}
      vpc_id: ${{ steps.vpc_id.outputs.value }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.11"

      - name: Bootstrap S3 Backend
        run: |
          if ! aws s3 ls "s3://$AWS_S3_TF_STATE_BUCKET_NAME" > /dev/null 2>&1; then
            echo "State Bucket does not exist. Creating..."
            aws s3 mb s3://$AWS_S3_TF_STATE_BUCKET_NAME --region $AWS_REGION
            echo "Waiting for bucket propagation..."
            sleep 15
          else
            echo "State Bucket already exists."
          fi

      - name: Terraform Init
        id: init
        run: terraform init -input=false -reconfigure -backend-config="bucket=$AWS_S3_TF_STATE_BUCKET_NAME"

      - name: Terraform Apply
        id: apply
        run: terraform apply -auto-approve -input=false

      - name: Read cluster_name output
        id: cluster_name
        run: echo "value=$(terraform output -raw cluster_name)" >> "$GITHUB_OUTPUT"

      - name: Read vpc_id output
        id: vpc_id
        run: echo "value=$(terraform output -raw vpc_id)" >> "$GITHUB_OUTPUT"

  install-load-balancer-controller:
    name: "Install AWS Load Balancer Controller + Ingress"
    needs: terraform-apply
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_SESSION_TOKEN: ${{ secrets.AWS_SESSION_TOKEN }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      CLUSTER_NAME: ${{ needs.terraform-apply.outputs.cluster_name }}
      VPC_ID: ${{ needs.terraform-apply.outputs.vpc_id }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Update Kubeconfig
        run: aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

      - name: Install AWS Load Balancer Controller
        run: |
          kubectl create secret generic aws-alb-credentials \
            --from-literal=AWS_ACCESS_KEY_ID=${{ secrets.AWS_ACCESS_KEY_ID }} \
            --from-literal=AWS_SECRET_ACCESS_KEY=${{ secrets.AWS_SECRET_ACCESS_KEY }} \
            --from-literal=AWS_SESSION_TOKEN=${{ secrets.AWS_SESSION_TOKEN }} \
            -n kube-system \
            --dry-run=client -o yaml | kubectl apply -f -

          helm repo add eks https://aws.github.io/eks-charts
          helm repo update eks
          helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=true \
            --set region="$AWS_REGION" \
            --set vpcId="$VPC_ID" \
            --set "envFrom[0].secretRef.name=aws-alb-credentials" \
            --wait

      - name: Apply centralized Ingress
        run: kubectl apply -f k8s/ingress.yaml
```

- [ ] **Step 2: Validate the workflow is well-formed YAML**

Run: `python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/infra-pipeline.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/infra-pipeline.yml
git commit -m "ci: add infra pipeline (terraform plan/apply, LB controller, centralized Ingress)"
```

---

### Task 8: Repo-wide formatting and final check

**Files:**
- Modify: any `.tf` file not already `terraform fmt`-clean

- [ ] **Step 1: Format check**

Run: `terraform fmt -recursive -check -diff`
Expected: no output, exit code 0. If it lists files, they need formatting.

- [ ] **Step 2: Apply formatting if Step 1 found diffs**

Run: `terraform fmt -recursive`

- [ ] **Step 3: Re-run both validations to confirm formatting didn't break anything**

Run:
```bash
cd prod && terraform validate && terraform test
cd ../dev && terraform validate
```
Expected: `prod` validate + all 5 tests pass; `dev` validate passes.

- [ ] **Step 4: Commit (only if Step 2 changed anything)**

```bash
git add -A
git commit -m "style: terraform fmt"
```
