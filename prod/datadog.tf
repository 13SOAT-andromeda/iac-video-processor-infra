# Datadog Agent no cluster EKS (observabilidade de infraestrutura) — DaemonSet
# de node agent + Cluster Agent via Helm chart oficial, coletando métricas de
# infra/containers, logs (autodiscovery) e recebendo os traces de APM
# publicados pelas aplicações via DD_AGENT_HOST (Downward API, status.hostIP).
#
# Gerenciado por Terraform (helm_release), não pelo pipeline CI (diferente do
# AWS Load Balancer Controller, seção 6 do spec de infra) — mantém a instalação
# 100% self-contained neste repo, sem depender de um pipeline que ainda não existe.
#
# Só existe em prod/: o LocalStack Community usado em dev/ não roda um control
# plane Kubernetes real (mesma limitação documentada para o ALB Controller —
# ver docs/superpowers/specs/2026-07-11-infra-design.md, seção 3.2), então os
# providers kubernetes/helm não teriam contra o que aplicar em dev/.

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "kubernetes_secret" "datadog" {
  metadata {
    name      = "datadog-secret"
    namespace = "default"
  }

  data = {
    api-key = var.datadog_api_key
  }

  type = "Opaque"
}

resource "helm_release" "datadog" {
  name       = "datadog-agent"
  repository = "https://helm.datadoghq.com"
  chart      = "datadog"
  version    = "3.231.5" # reconsultar Artifact Hub antes do apply real
  namespace  = "default"

  set_sensitive {
    name  = "datadog.apiKeyExistingSecret"
    value = kubernetes_secret.datadog.metadata[0].name
  }

  set {
    name  = "datadog.site"
    value = var.datadog_site
  }

  # env fica como tag (convenção "unified service tagging" do Datadog — tags
  # com a chave "env" alimentam o facet especial de ambiente na UI), não como
  # datadog.env: esse campo do chart espera uma LISTA de variáveis extras
  # ([{name: ..., value: ...}], estilo env do Kubernetes), não uma string —
  # setar como string quebra o `range` do template Helm.
  set {
    name  = "datadog.tags[0]"
    value = "project:video-processor"
  }

  set {
    name  = "datadog.tags[1]"
    value = "env:${var.environment}"
  }

  # APM — recebe os traces publicados pelos pods (links-service, users-api,
  # futuros serviços) via DD_AGENT_HOST=status.hostIP:8126.
  set {
    name  = "datadog.apm.portEnabled"
    value = "true"
  }

  # Logs de todos os containers do cluster (autodiscovery — sem anotação por
  # pod), incluindo o consumer goroutine do links-service.
  set {
    name  = "datadog.logs.enabled"
    value = "true"
  }

  set {
    name  = "datadog.logs.containerCollectAll"
    value = "true"
  }

  # Cluster Agent — reduz carga no control plane do EKS (um watcher central em
  # vez de cada node agent falando direto com a API do Kubernetes) e habilita
  # Cluster Checks / autoscaling metrics.
  set {
    name  = "clusterAgent.enabled"
    value = "true"
  }

  set {
    name  = "datadog.kubelet.tlsVerify"
    value = "false" # AMI gerenciada (AL2023) não expõe o CA do kubelet por padrão
  }
}
