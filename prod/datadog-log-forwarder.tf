# Datadog Lambda Log Forwarder: subscribes to CloudWatch Log Groups for the
# authorizer/authentication Lambdas and the API Gateway access logs, and
# ships those log events to Datadog.

resource "aws_secretsmanager_secret" "datadog_api_key" {
  name = "datadog-api-key-${var.environment}"

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "datadog_api_key" {
  secret_id     = aws_secretsmanager_secret.datadog_api_key.id
  secret_string = var.datadog_api_key
}

module "datadog_log_forwarder" {
  source  = "DataDog/log-lambda-forwarder-datadog/aws"
  version = "~> 1.4"

  function_name = "video-processor-datadog-forwarder-${var.environment}"

  # AWS Academy Lab denies iam:CreateRole — reuse LabRole instead of letting
  # the module create its own execution role. LabRole must already have the
  # permissions this forwarder needs (logs:PutLogEvents, S3 read/write for
  # the failed-events bucket, secretsmanager:GetSecretValue, etc.).
  existing_iam_role_arn = data.aws_iam_role.lab_role.arn

  # The secret is created above, in this same plan, not by the module.
  create_dd_api_key_secret = false
  dd_api_key_secret_arn    = aws_secretsmanager_secret.datadog_api_key.arn

  dd_site = var.datadog_site

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }

  depends_on = [aws_secretsmanager_secret_version.datadog_api_key]
}

locals {
  # Lambda log groups are created by the terraform-aws-modules/lambda/aws
  # module (default create_cloudwatch_log_group = true) in the
  # video-processor-authorizer and video-processor-authentication-api repos
  # — different Terraform states. Referenced here by their fixed,
  # convention-based name (/aws/lambda/<function_name>), same cross-repo
  # pattern already used for jwt-signing-key. These subscription filters
  # assume those log groups already exist by the time this plan applies.
  datadog_forwarded_lambda_log_groups = {
    authorizer     = "/aws/lambda/video-processor-authorizer"
    authentication = "/aws/lambda/video-processor-authentication"
  }
}

# API Gateway access log group is created by the
# terraform-aws-modules/apigateway-v2/aws module in
# iac-video-processor-gateway/prod (a different repo/state). Its name comes
# from that module's default: /aws/apigateway/<api-name>/<stage, $ stripped>.
# api-name there is "video-processor-api-gateway-${var.environment}" and the
# HTTP API stage is the default "$default" stage.
#
# Gated behind var.enable_downstream_log_forwarding (see variables.tf):
# this data source and the subscription filters below only resolve once the
# target log groups actually exist, which requires video-processor-authorizer,
# video-processor-authentication-api and iac-video-processor-gateway to have
# already been applied. On a fresh account (nothing deployed yet), leaving
# this at its default `false` lets `terraform apply` here succeed and
# provision the Datadog Agent/forwarder infrastructure itself; flip it to
# `true` in a later apply once those other repos/states exist.
data "aws_cloudwatch_log_group" "api_gateway_access_logs" {
  count = var.enable_downstream_log_forwarding ? 1 : 0
  name  = "/aws/apigateway/video-processor-api-gateway-${var.environment}/default"
}

# NOTE: no aws_lambda_permission resources are added here — the module
# already creates a single account-wide "logs.amazonaws.com" invoke
# permission (source_arn = log-group:*:*) covering every subscription
# filter that targets this forwarder, including the ones below.

resource "aws_cloudwatch_log_subscription_filter" "datadog_forwarder_authorizer" {
  count           = var.enable_downstream_log_forwarding ? 1 : 0
  name            = "datadog-forwarder-authorizer-${var.environment}"
  log_group_name  = local.datadog_forwarded_lambda_log_groups.authorizer
  filter_pattern  = ""
  destination_arn = module.datadog_log_forwarder.datadog_forwarder_arn
}

resource "aws_cloudwatch_log_subscription_filter" "datadog_forwarder_authentication" {
  count           = var.enable_downstream_log_forwarding ? 1 : 0
  name            = "datadog-forwarder-authentication-${var.environment}"
  log_group_name  = local.datadog_forwarded_lambda_log_groups.authentication
  filter_pattern  = ""
  destination_arn = module.datadog_log_forwarder.datadog_forwarder_arn
}

resource "aws_cloudwatch_log_subscription_filter" "datadog_forwarder_api_gateway" {
  count           = var.enable_downstream_log_forwarding ? 1 : 0
  name            = "datadog-forwarder-api-gateway-${var.environment}"
  log_group_name  = data.aws_cloudwatch_log_group.api_gateway_access_logs[0].name
  filter_pattern  = ""
  destination_arn = module.datadog_log_forwarder.datadog_forwarder_arn
}
