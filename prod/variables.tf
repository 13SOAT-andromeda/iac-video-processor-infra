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

variable "enable_postgres_dbm" {
  description = "Whether to configure the Cluster Agent's Postgres check against the users-db RDS instance (Datadog Database Monitoring). Requires iac-video-processor-data to already be applied (the RDS endpoint must exist) and prod/dbm_setup.sql already run against it (dedicated datadog DB user + pg_stat_statements). Leave false on first apply of this repo, flip to true afterward and set postgres_dbm_host."
  type        = bool
  default     = false
}

variable "postgres_dbm_host" {
  description = "RDS endpoint hostname (no port) of the users-db instance, from iac-video-processor-data's rds_endpoint output. Only used when enable_postgres_dbm = true."
  type        = string
  default     = ""
}

variable "postgres_dbm_port" {
  description = "RDS endpoint port of the users-db instance. Only used when enable_postgres_dbm = true."
  type        = number
  default     = 5432
}

variable "postgres_dbm_dbname" {
  description = "Database name to monitor. Only used when enable_postgres_dbm = true."
  type        = string
  default     = "usersdb"
}
