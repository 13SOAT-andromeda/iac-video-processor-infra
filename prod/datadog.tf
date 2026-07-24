# Datadog Agent (node Agent + Cluster Agent) deployed on the EKS cluster
# via the official Helm chart.
#
# No IRSA in this account (iam:CreateRole is denied under AWS Academy Lab):
# Agent pods do not get a service-account -> IAM role annotation anywhere
# below. Where the Agent needs AWS credentials it falls back to the node's
# LabRole instance profile via IMDS, which requires the hop-limit fix in
# prod/launch_template.tf.

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# Same namespace as the rest of the workload (k8s/ingress.yaml, users-api svc).
resource "kubernetes_secret_v1" "datadog_api_key" {
  metadata {
    name      = "datadog-secret"
    namespace = "default"
  }

  data = {
    api-key = var.datadog_api_key
  }

  type = "Opaque"

  depends_on = [aws_eks_node_group.users]
}

resource "helm_release" "datadog" {
  name       = "datadog"
  repository = "https://helm.datadoghq.com"
  chart      = "datadog"
  namespace  = "default"

  values = [
    yamlencode({
      datadog = {
        site                 = var.datadog_site
        apiKeyExistingSecret = kubernetes_secret_v1.datadog_api_key.metadata[0].name

        # "team" is the only custom tag key allowed by this org's Tag
        # Governance policy (same policy that rejected "project:..." on the
        # observability dashboard import) — "env" is a Datadog standard/
        # unified-service-tagging key and isn't subject to that allowlist.
        tags = [
          "team:video-processor",
          "env:${var.environment}",
        ]

        apm = {
          portEnabled = true
        }

        # Custom app metrics (users-api business flows) go out over DogStatsD
        # UDP to the node's hostPort — same reasoning as APM's portEnabled
        # above: pods reach the Agent via DD_AGENT_HOST=status.hostIP, and
        # the chart doesn't expose this hostPort by default.
        dogstatsd = {
          useHostPort = true
        }

        logs = {
          enabled             = true
          containerCollectAll = true
        }

        # No custom kubelet CA cert is provisioned on these nodes.
        kubelet = {
          tlsVerify = false
        }
      }

      # Postgres check for DBM (see datadog-dbm.tf) runs as a cluster check
      # — dispatched once by the Cluster Agent instead of duplicated on
      # every node agent — since the target (RDS) isn't a local pod.
      clusterAgent = {
        enabled = true

        confd = var.enable_postgres_dbm ? {
          "postgres.yaml" = yamlencode({
            cluster_check = true
            init_config   = {}
            instances = [
              {
                host     = var.postgres_dbm_host
                port     = var.postgres_dbm_port
                username = "datadog"
                password = random_password.datadog_db_user[0].result
                dbname   = var.postgres_dbm_dbname
                dbm      = true
              }
            ]
          })
        } : {}
      }
    })
  ]

  depends_on = [aws_eks_node_group.users, kubernetes_secret_v1.datadog_api_key]
}
