############################ Nightly red team ############################
# A SEPARATE Fargate task (not a service, no load balancer) that EventBridge Scheduler starts every night. It attacks the real pipeline
# (guard, language policy, Llama Prompt Guard 2, prompts, MiniMax, output rails) with a fresh set of attacks, writes a timestamped report to
# S3 (redteam/<UTC timestamp>/report.html and summary.json), emits CloudWatch metrics (Embedded Metric Format, Service=redteam) and, when a
# canary leaked, publishes to the alarm topic. See docs/redteam-nightly.md and scripts/redteam-nightly-aws.sh.
#
# Paused environment: there is no NAT gateway, so the task could not reach the model API. The schedule is disabled and the alarms are removed.
# Bootstrap first: the ECR repository quizforge/redteam is created by infra/bootstrap (the deploy pipeline pushes the image to it).

locals {
  redteam_on     = var.redteam_enabled && !var.paused
  reports_bucket = "${var.project}-${var.environment}-reports-${data.aws_caller_identity.current.account_id}"
}

############################ Reports bucket ############################

resource "aws_kms_key" "reports" {
  description             = "${local.name} red team reports"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "reports" {
  name          = "alias/${local.name}-reports"
  target_key_id = aws_kms_key.reports.key_id
}

resource "aws_s3_bucket" "reports" {
  bucket = local.reports_bucket
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.reports.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    id     = "age-out-reports"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration { days = 365 }
    noncurrent_version_expiration { noncurrent_days = 30 } # the overwritten redteam/latest/ files
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
  depends_on = [aws_s3_bucket_versioning.reports]
}

data "aws_iam_policy_document" "reports_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.reports.arn, "${aws_s3_bucket.reports.arn}/*"]
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

resource "aws_s3_bucket_policy" "reports" {
  bucket     = aws_s3_bucket.reports.id
  policy     = data.aws_iam_policy_document.reports_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.reports]
}

############################ IAM ############################

# Execution role: pulls the image, writes logs, reads ONE secret (the model key). Not the shared exec role: that one reads the database secret too.
resource "aws_iam_role" "redteam_exec" {
  name               = "${local.name}-redteam-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}
resource "aws_iam_role_policy_attachment" "redteam_exec" {
  role       = aws_iam_role.redteam_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy" "redteam_exec_secret" {
  name = "model-key"
  role = aws_iam_role.redteam_exec.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.llm.arn }]
  })
}

# Task role: what the red team code may do. Write reports (new keys under redteam/ only), read them to sign a link, tell the alarm topic.
resource "aws_iam_role" "redteam" {
  name               = "${local.name}-redteam"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}
resource "aws_iam_role_policy" "redteam" {
  name = "reports-and-alarm"
  role = aws_iam_role.redteam.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "WriteReports", Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.reports.arn}/redteam/*" },
      { Sid = "ReadForPresign", Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.reports.arn}/redteam/*" },
      { Sid = "ReportsKey", Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = aws_kms_key.reports.arn },
      { Sid = "AlarmTopic", Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.alarms.arn },
      { Sid = "AlarmTopicKey", Effect = "Allow", Action = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = aws_kms_key.alarms.arn },
    ]
  })
}

############################ Network ############################

# Egress only: the task calls the model API (through the NAT gateway) and ECR, S3 and SNS. Nothing connects to it, and it cannot reach the database.
resource "aws_security_group" "redteam" {
  name        = "${local.name}-redteam"
  description = "Nightly red team task: egress only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-redteam" }
}
#trivy:ignore:AVD-AWS-0104 deliberate: the task must reach the model API, ECR, S3 and SNS (through the NAT gateway); nothing can connect IN to it, and it has no route to the database
resource "aws_vpc_security_group_egress_rule" "redteam_out" {
  security_group_id = aws_security_group.redteam.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "outbound"
}

############################ Task definition ############################

resource "aws_ecs_task_definition" "redteam" {
  family                   = "${local.name}-redteam"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.redteam_cpu
  memory                   = var.redteam_memory
  execution_role_arn       = aws_iam_role.redteam_exec.arn
  task_role_arn            = aws_iam_role.redteam.arn
  runtime_platform {
    cpu_architecture        = local.runtime.cpu_architecture
    operating_system_family = local.runtime.operating_system_family
  }
  container_definitions = jsonencode([{
    name      = "redteam"
    image     = local.image.redteam
    essential = true
    command   = ["scripts/redteam-nightly-aws.sh"]
    environment = concat(
      [
        { name = "NODE_ENV", value = "production" },
        { name = "AWS_REGION", value = var.region },
        { name = "REPORT_BUCKET", value = aws_s3_bucket.reports.bucket },
        { name = "ALARM_TOPIC_ARN", value = aws_sns_topic.alarms.arn },
        { name = "REDTEAM_NUM_TESTS", value = tostring(var.redteam_num_tests) },
        { name = "MINIMAX_MODEL", value = var.minimax_model },
      ],
      # same detector setting as the generation worker, so the nightly run mirrors production (off = the model is not loaded)
      var.injection_detector == "off" ? [{ name = "INJECTION_DETECTOR_MODEL_DIR", value = "" }] : [{ name = "REDTEAM_DETECTOR_MODE", value = var.injection_detector }],
    )
    secrets          = [{ name = "MINIMAX_API_KEY", valueFrom = "${aws_secretsmanager_secret.llm.arn}:MINIMAX_API_KEY::" }]
    logConfiguration = local.log.redteam
  }])
}

############################ Schedule ############################

data "aws_iam_policy_document" "redteam_scheduler" {
  statement {
    sid       = "RunTheRedTeamTask"
    actions   = ["ecs:RunTask"]
    resources = [replace(aws_ecs_task_definition.redteam.arn, "/:\\d+$/", ":*")]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }
  statement {
    sid       = "PassItsTwoRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.redteam_exec.arn, aws_iam_role.redteam.arn]
  }
}

resource "aws_iam_role" "redteam_scheduler" {
  name               = "${local.name}-redteam-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}
resource "aws_iam_role_policy" "redteam_scheduler" {
  name   = "run-redteam"
  role   = aws_iam_role.redteam_scheduler.id
  policy = data.aws_iam_policy_document.redteam_scheduler.json
}

resource "aws_scheduler_schedule" "redteam" {
  name                = "${local.name}-redteam"
  description         = "Nightly red team run (a Fargate task that writes its report to S3)"
  schedule_expression = var.redteam_schedule
  state               = local.redteam_on ? "ENABLED" : "DISABLED" # paused: no NAT gateway, the task could not reach the model API
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_ecs_cluster.main.arn
    role_arn = aws_iam_role.redteam_scheduler.arn
    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.redteam.arn
      launch_type         = "FARGATE"
      task_count          = 1
      network_configuration {
        subnets          = aws_subnet.app[*].id
        security_groups  = [aws_security_group.redteam.id]
        assign_public_ip = false
      }
    }
    retry_policy {
      maximum_retry_attempts       = 0 # a failed night shows up as the "run missing" alarm; a retry would pay for the model twice
      maximum_event_age_in_seconds = 3600
    }
  }
}

############################ Alarms ############################

resource "aws_cloudwatch_metric_alarm" "redteam_leak" {
  count               = local.redteam_on ? 1 : 0
  alarm_name          = "${local.name}-redteam-leak"
  alarm_description   = "The nightly red team run found a canary in a reply: the model obeyed an instruction hidden in a document. Open redteam/latest/report.html (scripts/redteam-latest.sh)"
  namespace           = "QuizForge"
  metric_name         = "RedteamLeaks"
  dimensions          = { Service = "redteam" }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "redteam_run_missing" {
  count               = local.redteam_on ? 1 : 0
  alarm_name          = "${local.name}-redteam-run-missing"
  alarm_description   = "No nightly red team run finished in the last 26 hours (the task failed, was never started, or produced no results). See the log group /${var.project}/${var.environment}/redteam"
  namespace           = "QuizForge"
  metric_name         = "RedteamRuns"
  dimensions          = { Service = "redteam" }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 26
  datapoints_to_alarm = 26
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
