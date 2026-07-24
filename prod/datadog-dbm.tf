# Datadog Database Monitoring (DBM) — Postgres check against the users-db
# RDS instance. Depends on iac-video-processor-data/prod/dbm_setup.sql
# already having created the dedicated `datadog` DB user + enabled
# pg_stat_statements — this file only handles the Agent side (see
# datadog.tf's clusterAgent.confd for where this password gets used).
#
# The password is generated here (Terraform-managed) rather than reusing
# whatever dbm_setup.sql was run with, so re-applying this repo doesn't
# require remembering a value that was deliberately never persisted
# anywhere when the SQL was first run. Whoever (re)runs dbm_setup.sql
# should set the `datadog` user's password to this secret's value
# (ALTER USER datadog WITH PASSWORD '...'), not the other way around.

resource "random_password" "datadog_db_user" {
  count   = var.enable_postgres_dbm ? 1 : 0
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "datadog_db_user_password" {
  count = var.enable_postgres_dbm ? 1 : 0
  name  = "datadog-postgres-dbm-password-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "datadog_db_user_password" {
  count         = var.enable_postgres_dbm ? 1 : 0
  secret_id     = aws_secretsmanager_secret.datadog_db_user_password[0].id
  secret_string = random_password.datadog_db_user[0].result
}
