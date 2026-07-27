mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/LabRole"
      name = "LabRole"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_eks_cluster_auth" {
    defaults = {
      token = "mock-token"
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  datadog_api_key = "mock-api-key"
}

run "datadog_secret_holds_the_api_key" {
  command = plan

  assert {
    condition     = kubernetes_secret_v1.datadog_api_key.metadata[0].name == "datadog-secret"
    error_message = "Expected the Datadog API key secret to be named datadog-secret — the helm_release references it by this exact name"
  }

  assert {
    condition     = kubernetes_secret_v1.datadog_api_key.data["api-key"] == "mock-api-key"
    error_message = "Expected the secret to carry the datadog_api_key variable, not a hardcoded value"
  }
}

run "datadog_helm_release_uses_official_chart" {
  command = plan

  assert {
    condition     = helm_release.datadog.repository == "https://helm.datadoghq.com"
    error_message = "Expected the official Datadog Helm repository"
  }

  assert {
    condition     = helm_release.datadog.chart == "datadog"
    error_message = "Expected the datadog/datadog chart (agent + cluster agent), not a different chart"
  }

  assert {
    condition     = helm_release.datadog.namespace == "default"
    error_message = "Expected the release in the default namespace, same as the future links-service/users-api Deployments"
  }
}

run "datadog_agent_enables_apm_and_logs" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.apm.portEnabled == true
    error_message = "Expected APM to be enabled — otherwise links-service/users-api traces would have nowhere to land"
  }

  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.logs.enabled == true
    error_message = "Expected log collection to be enabled"
  }

  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.logs.containerCollectAll == true
    error_message = "Expected containerCollectAll so logs are collected via autodiscovery without per-pod annotations"
  }

  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).clusterAgent.enabled == true
    error_message = "Expected the Cluster Agent to be enabled (reduces load on the EKS control plane vs. each node agent watching the API directly)"
  }
}

run "datadog_tags_use_org_governed_keys" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = contains(yamldecode(helm_release.datadog.values[0]).datadog.tags, "team:video-processor")
    error_message = "Expected a team:video-processor tag — \"team\" is one of the only two custom tag keys this org's Tag Governance policy allows"
  }

  assert {
    condition     = contains(yamldecode(helm_release.datadog.values[0]).datadog.tags, "env:prod")
    error_message = "Expected an env:<environment> tag — \"env\" is a Datadog standard/unified-service-tagging key, not subject to the custom tag allowlist"
  }
}

run "datadog_site_defaults_to_us5" {
  command = plan

  assert {
    condition     = var.datadog_site == "us5.datadoghq.com"
    error_message = "Expected the default Datadog site to be us5.datadoghq.com — this org's Datadog account lives on us5, not the generic datadoghq.com (US1) site"
  }
}

run "postgres_dbm_check_omitted_by_default" {
  command = plan

  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).clusterAgent.confd == {}
    error_message = "Expected no Postgres check config when enable_postgres_dbm is false (default) — the RDS endpoint doesn't exist yet on a fresh apply of this repo"
  }
}

run "postgres_dbm_check_wired_when_enabled" {
  command = plan

  variables {
    enable_postgres_dbm = true
    postgres_dbm_host   = "video-processor-users-db-prod.example.us-east-1.rds.amazonaws.com"
  }

  # random_password's result is Optional+Computed, so it's "known after
  # apply" for a resource not yet in state — command = plan alone can't
  # resolve helm_release.datadog's values, which reference it. Same
  # override_during = plan technique already used elsewhere in this repo's
  # tests (see infra_unit_test.tftest.hcl).
  override_resource {
    target = random_password.datadog_db_user[0]
    values = {
      result = "mock-postgres-dbm-password"
    }
    override_during = plan
  }

  assert {
    condition = (
      yamldecode(yamldecode(helm_release.datadog.values[0]).clusterAgent.confd["postgres.yaml"]).instances[0].host
      == "video-processor-users-db-prod.example.us-east-1.rds.amazonaws.com"
    )
    error_message = "Expected the Postgres check's instance host to be postgres_dbm_host when DBM is enabled"
  }

  assert {
    condition = (
      yamldecode(yamldecode(helm_release.datadog.values[0]).clusterAgent.confd["postgres.yaml"]).instances[0].dbm
      == true
    )
    error_message = "Expected dbm: true — otherwise this is just the basic Postgres integration, not Database Monitoring"
  }

  assert {
    condition = (
      yamldecode(yamldecode(helm_release.datadog.values[0]).clusterAgent.confd["postgres.yaml"]).cluster_check
      == true
    )
    error_message = "Expected cluster_check: true — RDS isn't a local pod, so this should run as a cluster check dispatched once, not duplicated per node agent"
  }
}
