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
  description = "Datadog API key (Organization Settings > API Keys). Nunca commitar um valor real — suprir via TF_VAR_datadog_api_key ou um .auto.tfvars fora do controle de versão."
  type        = string
  sensitive   = true
}

variable "datadog_site" {
  description = "Datadog site (ex.: datadoghq.com, datadoghq.eu, us5.datadoghq.com)"
  type        = string
  default     = "datadoghq.com"
}
