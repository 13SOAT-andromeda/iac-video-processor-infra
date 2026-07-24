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

variable "datadog_api_key" {
  description = "Datadog API key (Organization Settings > API Keys). Usada pelo Cluster Agent (k8s secret) e pelo Lambda log forwarder. Nunca commitar um valor real — suprir via TF_VAR_datadog_api_key ou um .auto.tfvars fora do controle de versão."
  type        = string
  sensitive   = true
}

variable "datadog_site" {
  description = "Datadog site (ex.: datadoghq.com, datadoghq.eu, us5.datadoghq.com)"
  type        = string
  default     = "datadoghq.com"
}

variable "enable_downstream_log_forwarding" {
  description = "Whether to wire up CloudWatch Log subscription filters (Lambda + API Gateway access logs) to the Datadog forwarder. Requires video-processor-authorizer, video-processor-authentication-api and iac-video-processor-gateway to already be applied (their log groups must exist). Leave false on first apply of this repo, flip to true afterward."
  type        = bool
  default     = false
}
