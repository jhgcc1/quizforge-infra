############################ Alerting ############################

# CloudWatch alarms and Budgets can only publish to an encrypted topic if the KEY POLICY lets them use the key:
# the AWS-managed alias/aws/sns key does not, so alerts would be silently dropped. Hence a customer-managed key.
data "aws_iam_policy_document" "alarms_key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid       = "AlarmServicesMayPublish"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com", "events.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "alarms" {
  description             = "${local.name} alarm topic"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.alarms_key.json
}

resource "aws_kms_alias" "alarms" {
  name          = "alias/${local.name}-alarms"
  target_key_id = aws_kms_key.alarms.key_id
}

resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-alarms"
  kms_master_key_id = aws_kms_key.alarms.arn
}

data "aws_iam_policy_document" "alarms_topic" {
  statement {
    sid       = "AllowAlarmsAndBudgets"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms_topic.json
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alarm_actions = [aws_sns_topic.alarms.arn]
  # (name => [metric, namespace, dimensions, statistic, period, evaluation periods, comparison, threshold, description])
  alarms = {
    dlq-not-empty = {
      ns   = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", dims = { QueueName = aws_sqs_queue.dlq.name }
      stat = "Maximum", period = 60, evals = 1, cmp = "GreaterThanOrEqualToThreshold", threshold = 1
      desc = "A quiz job exhausted its retries and landed in the dead-letter queue"
    }
    scoring-dlq-not-empty = {
      ns   = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", dims = { QueueName = aws_sqs_queue.scoring_dlq.name }
      stat = "Maximum", period = 60, evals = 1, cmp = "GreaterThanOrEqualToThreshold", threshold = 1
      desc = "A scoring job exhausted its retries: a quiz is ready but has no quality score"
    }
    scoring-queue-too-old = {
      ns   = "AWS/SQS", metric = "ApproximateAgeOfOldestMessage", dims = { QueueName = aws_sqs_queue.scoring.name }
      stat = "Maximum", period = 60, evals = 5, cmp = "GreaterThanThreshold", threshold = 900
      desc = "Scoring is more than 15 minutes behind: quizzes are ready but not scored yet"
    }
    queue-too-old = {
      ns   = "AWS/SQS", metric = "ApproximateAgeOfOldestMessage", dims = { QueueName = aws_sqs_queue.jobs.name }
      stat = "Maximum", period = 60, evals = 5, cmp = "GreaterThanThreshold", threshold = 600
      desc = "Jobs have waited more than 10 minutes: workers are down or overloaded"
    }
    alb-5xx = {
      ns   = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", dims = { LoadBalancer = aws_lb.main.arn_suffix }
      stat = "Sum", period = 300, evals = 1, cmp = "GreaterThanOrEqualToThreshold", threshold = 10
      desc = "The services are returning 5xx errors"
    }
    api-cpu-high = {
      ns   = "AWS/ECS", metric = "CPUUtilization", dims = { ClusterName = aws_ecs_cluster.main.name, ServiceName = "api" }
      stat = "Average", period = 300, evals = 3, cmp = "GreaterThanThreshold", threshold = 85
      desc = "API CPU is saturated even after scaling out"
    }
    web-cpu-high = {
      ns   = "AWS/ECS", metric = "CPUUtilization", dims = { ClusterName = aws_ecs_cluster.main.name, ServiceName = "web" }
      stat = "Average", period = 300, evals = 3, cmp = "GreaterThanThreshold", threshold = 85
      desc = "Web CPU is saturated even after scaling out"
    }
    rds-cpu-high = {
      ns   = "AWS/RDS", metric = "CPUUtilization", dims = { DBInstanceIdentifier = aws_db_instance.main.identifier }
      stat = "Average", period = 300, evals = 3, cmp = "GreaterThanThreshold", threshold = 80
      desc = "Database CPU is high"
    }
    rds-storage-low = {
      ns   = "AWS/RDS", metric = "FreeStorageSpace", dims = { DBInstanceIdentifier = aws_db_instance.main.identifier }
      stat = "Minimum", period = 300, evals = 1, cmp = "LessThanThreshold", threshold = 2147483648
      desc = "Less than 2 GiB of database storage left"
    }
    # --- application metrics emitted by the worker (CloudWatch Embedded Metric Format) ---
    quiz-quality-low = {
      ns   = "QuizForge", metric = "QuizQuality", dims = { Service = "worker" }
      stat = "Average", period = 3600, evals = 1, cmp = "LessThanThreshold", threshold = var.min_quality_score
      desc = "Generated quiz quality (deterministic checks + LLM judge) dropped below the minimum"
    }
    # A 1-hour average hides one terrible quiz among good ones: this fires on the WORST single quiz in any 5 minutes.
    quiz-quality-critical = {
      ns   = "QuizForge", metric = "QuizQuality", dims = { Service = "worker" }
      stat = "Minimum", period = 300, evals = 1, cmp = "LessThanThreshold", threshold = var.critical_quality_score
      desc = "A single generated quiz scored below the critical quality threshold"
    }
    # Without a judge score a quiz has no quality value, so the two alarms above would stay silent: alarm on the blind spot too.
    judge-failing = {
      ns   = "QuizForge", metric = "JudgeFailed", dims = { Service = "worker" }
      stat = "Sum", period = 900, evals = 1, cmp = "GreaterThanOrEqualToThreshold", threshold = 3
      desc = "The LLM judge keeps failing, so quiz quality is not being measured"
    }
    job-failures = {
      ns   = "QuizForge", metric = "JobFailed", dims = { Service = "worker" }
      stat = "Sum", period = 900, evals = 1, cmp = "GreaterThanOrEqualToThreshold", threshold = 3
      desc = "Quiz generation is failing repeatedly"
    }
    llm-cost-daily = {
      ns   = "QuizForge", metric = "QuizCostUsd", dims = { Service = "worker" }
      stat = "Sum", period = 86400, evals = 1, cmp = "GreaterThanThreshold", threshold = var.daily_llm_cost_alarm_usd
      desc = "Daily LLM spend is above the configured limit"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "app" {
  for_each            = local.alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.desc
  namespace           = each.value.ns
  metric_name         = each.value.metric
  dimensions          = each.value.dims
  statistic           = each.value.stat
  period              = each.value.period
  evaluation_periods  = each.value.evals
  comparison_operator = each.value.cmp
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  dynamic "notification" {
    for_each = var.alarm_email == "" ? [] : [80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value == 80 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = [var.alarm_email]
    }
  }
}

############################ Dashboard ############################

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
        title = "Jobs: waiting / in flight / dead", region = var.region, stat = "Maximum", period = 60
        metrics = [
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.jobs.name, { label = "waiting" }],
          [".", "ApproximateNumberOfMessagesNotVisible", ".", ".", { label = "in flight" }],
          [".", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq.name, { label = "dead-letter" }],
      ] } },
      { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
        title = "Quiz quality (0-1) and failures", region = var.region, period = 3600
        metrics = [
          ["QuizForge", "QuizQuality", "Service", "worker", { stat = "Average", label = "avg quality" }],
          [".", "JobFailed", ".", ".", { stat = "Sum", label = "failures", yAxis = "right" }],
      ] } },
      { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = {
        title = "LLM cost (USD) and latency", region = var.region, period = 3600
        metrics = [
          ["QuizForge", "QuizCostUsd", "Service", "worker", { stat = "Sum", label = "cost USD" }],
          [".", "GenerationLatencyMs", ".", ".", { stat = "Average", label = "avg latency ms", yAxis = "right" }],
      ] } },
      { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = {
        title = "Service CPU (%)", region = var.region, stat = "Average", period = 300
        metrics = [
          ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", "web"],
          ["...", "api"],
          ["...", "worker"],
      ] } },
      { type = "metric", x = 0, y = 12, width = 12, height = 6, properties = {
        title = "ALB requests and 5xx", region = var.region, period = 300, stat = "Sum"
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix],
          [".", "HTTPCode_Target_5XX_Count", ".", "."],
      ] } },
      { type = "log", x = 12, y = 12, width = 12, height = 6, properties = {
        title = "Recent errors (all services)", region = var.region, view = "table"
        query = "SOURCE '${aws_cloudwatch_log_group.svc["api"].name}' | SOURCE '${aws_cloudwatch_log_group.svc["worker"].name}' | SOURCE '${aws_cloudwatch_log_group.svc["web"].name}' | fields @timestamp, @log, msg, quizId, requestId | filter level = 'error' or level >= 50 | sort @timestamp desc | limit 20"
      } },
    ]
  })
}

############################ Sweeper schedule ############################

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "run-sweeper"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecs:RunTask"], Resource = replace(aws_ecs_task_definition.sweeper.arn, "/:\\d+$/", ":*") },
      { Effect = "Allow", Action = ["iam:PassRole"], Resource = [aws_iam_role.exec.arn, aws_iam_role.worker.arn] },
    ]
  })
}

resource "aws_scheduler_schedule" "sweeper" {
  name                = "${local.name}-sweeper"
  schedule_expression = "rate(5 minutes)"
  state               = var.paused ? "DISABLED" : "ENABLED"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_ecs_cluster.main.arn
    role_arn = aws_iam_role.scheduler.arn
    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.sweeper.arn
      launch_type         = "FARGATE"
      task_count          = 1
      network_configuration {
        subnets          = aws_subnet.app[*].id
        security_groups  = [aws_security_group.worker.id]
        assign_public_ip = false
      }
    }
    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 300
    }
  }
}
