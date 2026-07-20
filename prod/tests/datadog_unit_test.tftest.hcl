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
    condition     = kubernetes_secret.datadog.metadata[0].name == "datadog-secret"
    error_message = "Expected the Datadog API key secret to be named datadog-secret — the helm_release references it by this exact name"
  }

  assert {
    condition     = kubernetes_secret.datadog.data["api-key"] == "mock-api-key"
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

  assert {
    condition = anytrue([
      for s in tolist(helm_release.datadog.set) : s.name == "datadog.apm.portEnabled" && s.value == "true"
    ])
    error_message = "Expected APM to be enabled — otherwise links-service/users-api traces would have nowhere to land"
  }

  assert {
    condition = anytrue([
      for s in tolist(helm_release.datadog.set) : s.name == "datadog.logs.enabled" && s.value == "true"
    ])
    error_message = "Expected log collection to be enabled"
  }

  assert {
    condition = anytrue([
      for s in tolist(helm_release.datadog.set) : s.name == "datadog.logs.containerCollectAll" && s.value == "true"
    ])
    error_message = "Expected containerCollectAll so logs are collected via autodiscovery without per-pod annotations"
  }

  assert {
    condition = anytrue([
      for s in tolist(helm_release.datadog.set) : s.name == "clusterAgent.enabled" && s.value == "true"
    ])
    error_message = "Expected the Cluster Agent to be enabled (reduces load on the EKS control plane vs. each node agent watching the API directly)"
  }
}

run "datadog_site_defaults_to_us1" {
  command = plan

  assert {
    condition     = var.datadog_site == "datadoghq.com"
    error_message = "Expected the default Datadog site to be datadoghq.com (US1) unless overridden"
  }
}
