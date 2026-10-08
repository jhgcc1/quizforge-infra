############################ PostgreSQL ############################

resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_db_parameter_group" "main" {
  name   = "${local.name}-pg16"
  family = "postgres16"
  parameter {
    name         = "rds.force_ssl"
    value        = "1"              # clients must use TLS; the apps verify the certificate (sslmode=verify-full)
    apply_method = "pending-reboot" # static parameter: AWS always stores it like this, "immediate" would show a diff forever
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

resource "aws_db_instance" "main" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "quizforge"
  username = "quizforge"
  # RDS generates the password and keeps it in Secrets Manager: it never appears in code, plans or CI logs.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period    = var.db_backup_retention_days
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = !var.deletion_protection
  final_snapshot_identifier  = var.deletion_protection ? "${local.name}-final" : null
  apply_immediately          = true

  enabled_cloudwatch_logs_exports = ["postgresql"]
}

############################ Queue ############################

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-jobs-dlq"
  message_retention_seconds = 14 * 24 * 3600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${local.name}-jobs"
  visibility_timeout_seconds = 360 # > longest job (5 min budget); the worker heartbeat extends it
  receive_wait_time_seconds  = 20  # long polling
  message_retention_seconds  = 4 * 24 * 3600
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3 # keep in sync with the worker's SQS_MAX_RECEIVE
  })
}

# Scoring: a second queue, so the judge runs in its own service and never holds up generation.
resource "aws_sqs_queue" "scoring_dlq" {
  name                      = "${local.name}-scoring-dlq"
  message_retention_seconds = 14 * 24 * 3600
  sqs_managed_sse_enabled   = true
}
resource "aws_sqs_queue" "scoring" {
  name                       = "${local.name}-scoring"
  visibility_timeout_seconds = 180 # a judge run takes ~20-30 s; the scorer heartbeat extends it
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 4 * 24 * 3600
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.scoring_dlq.arn
    maxReceiveCount     = 3 # keep in sync with SQS_MAX_RECEIVE of the scorer
  })
}

data "aws_iam_policy_document" "tls_only" {
  for_each = { jobs = aws_sqs_queue.jobs.arn, dlq = aws_sqs_queue.dlq.arn, scoring = aws_sqs_queue.scoring.arn, scoring_dlq = aws_sqs_queue.scoring_dlq.arn }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "tls_only" {
  for_each  = { jobs = aws_sqs_queue.jobs.url, dlq = aws_sqs_queue.dlq.url, scoring = aws_sqs_queue.scoring.url, scoring_dlq = aws_sqs_queue.scoring_dlq.url }
  queue_url = each.value
  policy    = data.aws_iam_policy_document.tls_only[each.key].json
}

############################ Secrets ############################
# Containers only: values are set out-of-band (scripts/set-secrets.sh) so they never enter Terraform state.

resource "aws_secretsmanager_secret" "llm" {
  name                    = "${local.name}/llm"
  description             = "MINIMAX_API_KEY"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "langfuse" {
  name                    = "${local.name}/langfuse"
  description             = "LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "cognito_web" {
  name                    = "${local.name}/cognito-web-client"
  description             = "Confidential client secret used only by the Next.js BFF"
  recovery_window_in_days = 0
}

# Secret VALUES are deliberately not Terraform resources. A resource would make every `terraform plan` call
# secretsmanager:GetSecretValue to refresh it, and the read-only role that PR branches use must never be able to
# read secrets. They are seeded once by this local-exec (needs the AWS CLI, run with the deploy role / an admin) and
# afterwards owned by scripts/set-secrets.sh (LLM + Langfuse keys). Placeholders only exist so that tasks can start
# on the very first deployment.
resource "terraform_data" "seed_llm_secrets" {
  triggers_replace = [aws_secretsmanager_secret.llm.arn, aws_secretsmanager_secret.langfuse.arn]
  provisioner "local-exec" {
    interpreter = ["bash", "-ec"]
    command     = <<-EOT
      seed() { # <secret> <json>: write only when the secret has no value yet, never overwrite a real one
        aws secretsmanager get-secret-value --region ${var.region} --secret-id "$1" >/dev/null 2>&1 \
          || aws secretsmanager put-secret-value --region ${var.region} --secret-id "$1" --secret-string "$2" >/dev/null
      }
      seed ${aws_secretsmanager_secret.llm.arn} '{"MINIMAX_API_KEY":"not-set-run-scripts-set-secrets"}'
      seed ${aws_secretsmanager_secret.langfuse.arn} '{"LANGFUSE_PUBLIC_KEY":"","LANGFUSE_SECRET_KEY":""}'
    EOT
  }
}

# The Cognito client secret is generated by AWS; copy it into Secrets Manager for the Next.js BFF.
resource "terraform_data" "seed_cognito_secret" {
  triggers_replace = [aws_cognito_user_pool_client.web.id, aws_secretsmanager_secret.cognito_web.arn]
  provisioner "local-exec" {
    interpreter = ["bash", "-ec"]
    environment = { CLIENT_SECRET = aws_cognito_user_pool_client.web.client_secret } # sensitive: not echoed
    command     = <<-EOT
      aws secretsmanager put-secret-value --region ${var.region} --secret-id ${aws_secretsmanager_secret.cognito_web.arn} \
        --secret-string "$(jq -nc --arg s "$CLIENT_SECRET" '{client_secret:$s}')" >/dev/null
    EOT
  }
}

# The secret versions created by an earlier iteration are forgotten, NOT destroyed (tasks keep their values).
removed {
  from = aws_secretsmanager_secret_version.llm_placeholder
  lifecycle { destroy = false }
}
removed {
  from = aws_secretsmanager_secret_version.langfuse_placeholder
  lifecycle { destroy = false }
}
removed {
  from = aws_secretsmanager_secret_version.cognito_web
  lifecycle { destroy = false }
}

# Shared secret between CloudFront and the ALB so the ALB refuses traffic that did not come through CloudFront.
resource "random_password" "origin_verify" {
  length  = 48
  special = false
}
