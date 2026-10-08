data "aws_ecr_repository" "svc" {
  for_each = toset(["web", "api", "worker"])
  name     = "${var.project}/${each.key}"
}

locals {
  image = { for k, r in data.aws_ecr_repository.svc : k => "${r.repository_url}:${var.image_tag}" }

  app_url     = "https://${aws_cloudfront_distribution.main.domain_name}"
  api_url     = "http://api.${var.project}.internal:8080"
  db_secret   = aws_db_instance.main.master_user_secret[0].secret_arn
  db_env      = [{ name = "DB_HOST", value = aws_db_instance.main.address }, { name = "DB_NAME", value = aws_db_instance.main.db_name }, { name = "DB_SSL", value = "true" }]
  db_secrets  = [{ name = "DB_USER", valueFrom = "${local.db_secret}:username::" }, { name = "DB_PASSWORD", valueFrom = "${local.db_secret}:password::" }]
  node_health = { for p in [3000, 8080, 8081] : tostring(p) => ["CMD", "node", "-e", "fetch('http://127.0.0.1:${p}/${p == 3000 ? "" : "healthz"}').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))"] }
}

resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "disabled" # service-level CPU/memory metrics are free; Insights adds cost
  }
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${var.project}.internal"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "api" {
  name = "api"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

############################ Logs ############################

resource "aws_cloudwatch_log_group" "svc" {
  for_each          = toset(["web", "api", "worker", "migrate", "sweeper"])
  name              = "/${var.project}/${var.environment}/${each.key}"
  retention_in_days = 30
}

############################ IAM ############################

data "aws_iam_policy_document" "ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Execution role: pulls images, writes logs, reads exactly the secrets the tasks reference.
resource "aws_iam_role" "exec" {
  name               = "${local.name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}
resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
data "aws_iam_policy_document" "exec_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      local.db_secret,
      aws_secretsmanager_secret.llm.arn,
      aws_secretsmanager_secret.langfuse.arn,
      aws_secretsmanager_secret.cognito_web.arn,
    ]
  }
}
resource "aws_iam_role_policy" "exec_secrets" {
  name   = "secrets"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec_secrets.json
}

# Task roles (what the application code itself may do)
resource "aws_iam_role" "api" {
  name               = "${local.name}-api"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}
resource "aws_iam_role_policy" "api" {
  name = "queue-send"
  role = aws_iam_role.api.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.jobs.arn }]
  })
}

resource "aws_iam_role" "worker" {
  name               = "${local.name}-worker"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}
resource "aws_iam_role_policy" "worker" {
  name = "queue-consume"
  role = aws_iam_role.worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:SendMessage"]
      Resource = aws_sqs_queue.jobs.arn
    }]
  })
}

############################ Task definitions ############################

locals {
  runtime = { cpu_architecture = var.cpu_architecture, operating_system_family = "LINUX" }
  log = { for k, g in aws_cloudwatch_log_group.svc : k => {
    logDriver = "awslogs"
    options   = { "awslogs-group" = g.name, "awslogs-region" = var.region, "awslogs-stream-prefix" = k }
  } }
}

resource "aws_ecs_task_definition" "web" {
  family                   = "${local.name}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.exec.arn
  runtime_platform {
    cpu_architecture        = local.runtime.cpu_architecture
    operating_system_family = local.runtime.operating_system_family
  }
  container_definitions = jsonencode([{
    name         = "web"
    image        = local.image.web
    essential    = true
    portMappings = [{ containerPort = 3000, protocol = "tcp" }]
    environment = [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "3000" },
      # ECS overwrites HOSTNAME with the container hostname, which would make Next bind to that one interface and
      # fail its own 127.0.0.1 health check. Bind explicitly to all interfaces.
      { name = "HOSTNAME", value = "0.0.0.0" },
      { name = "AUTH_MODE", value = "cognito" },
      { name = "COGNITO_DOMAIN", value = local.cognito_domain_url },
      { name = "COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.web.id },
      { name = "APP_URL", value = local.app_url },
      { name = "API_URL", value = local.api_url },
    ]
    secrets          = [{ name = "COGNITO_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.cognito_web.arn}:client_secret::" }]
    logConfiguration = local.log.web
    healthCheck      = { command = local.node_health["3000"], interval = 15, timeout = 5, retries = 3, startPeriod = 20 }
    stopTimeout      = 30
  }])
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.api.arn
  runtime_platform {
    cpu_architecture        = local.runtime.cpu_architecture
    operating_system_family = local.runtime.operating_system_family
  }
  container_definitions = jsonencode([{
    name         = "api"
    image        = local.image.api
    essential    = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]
    environment = concat(local.db_env, [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "8080" },
      { name = "AUTH_MODE", value = "cognito" },
      { name = "COGNITO_USER_POOL_ID", value = aws_cognito_user_pool.main.id },
      { name = "COGNITO_CLIENT_IDS", value = join(",", local.cognito_client_ids) },
      { name = "QUEUE_MODE", value = "sqs" },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.jobs.url },
      { name = "DEFAULT_SOURCE_URL", value = var.default_source_url },
      { name = "DAILY_QUIZ_QUOTA", value = tostring(var.daily_quiz_quota) },
    ])
    secrets          = local.db_secrets
    logConfiguration = local.log.api
    healthCheck      = { command = local.node_health["8080"], interval = 15, timeout = 5, retries = 3, startPeriod = 30 }
    stopTimeout      = 30
  }])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.worker.arn
  runtime_platform {
    cpu_architecture        = local.runtime.cpu_architecture
    operating_system_family = local.runtime.operating_system_family
  }
  container_definitions = jsonencode([{
    name      = "worker"
    image     = local.image.worker
    essential = true
    environment = concat(local.db_env, var.minimax_judge_model == "" ? [] : [{ name = "MINIMAX_JUDGE_MODEL", value = var.minimax_judge_model }], [
      { name = "NODE_ENV", value = "production" },
      { name = "LLM_MODE", value = "minimax" },
      { name = "MINIMAX_MODEL", value = var.minimax_model },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.jobs.url },
      { name = "SQS_MAX_RECEIVE", value = "3" },
      { name = "SQS_VISIBILITY_TIMEOUT", value = "360" },
      { name = "WORKER_CONCURRENCY", value = "1" },
      { name = "SHUTDOWN_GRACE_MS", value = "100000" },
      { name = "LANGFUSE_BASE_URL", value = "https://us.cloud.langfuse.com" },
    ])
    secrets = concat(local.db_secrets, [
      { name = "MINIMAX_API_KEY", valueFrom = "${aws_secretsmanager_secret.llm.arn}:MINIMAX_API_KEY::" },
      { name = "LANGFUSE_PUBLIC_KEY", valueFrom = "${aws_secretsmanager_secret.langfuse.arn}:LANGFUSE_PUBLIC_KEY::" },
      { name = "LANGFUSE_SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.langfuse.arn}:LANGFUSE_SECRET_KEY::" },
    ])
    logConfiguration = local.log.worker
    healthCheck      = { command = local.node_health["8081"], interval = 30, timeout = 5, retries = 3, startPeriod = 40 }
    stopTimeout      = 120 # Fargate maximum: in-flight jobs finish or resume from their checkpoint
  }])
}

# One-off tasks launched by the pipeline / scheduler (not services).
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${local.name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.exec.arn
  runtime_platform {
    cpu_architecture        = local.runtime.cpu_architecture
    operating_system_family = local.runtime.operating_system_family
  }
  container_definitions = jsonencode([{
    name             = "migrate"
    image            = local.image.api
    essential        = true
    command          = ["node", "--import", "tsx", "node_modules/@quizforge/db/src/migrate.ts"]
    environment      = concat(local.db_env, [{ name = "NODE_ENV", value = "production" }])
    secrets          = local.db_secrets
    logConfiguration = local.log.migrate
  }])
}

resource "aws_ecs_task_definition" "sweeper" {
  family                   = "${local.name}-sweeper"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.worker.arn
  runtime_platform {
    cpu_architecture        = local.runtime.cpu_architecture
    operating_system_family = local.runtime.operating_system_family
  }
  container_definitions = jsonencode([{
    name      = "sweeper"
    image     = local.image.worker
    essential = true
    command   = ["node", "--import", "tsx", "src/sweeper.ts"]
    environment = concat(local.db_env, [
      { name = "NODE_ENV", value = "production" },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.jobs.url },
    ])
    secrets          = local.db_secrets
    logConfiguration = local.log.sweeper
  }])
}

############################ Services ############################

locals {
  svc_common = {
    cluster                            = aws_ecs_cluster.main.id
    launch_type                        = "FARGATE"
    deployment_minimum_healthy_percent = 100
    deployment_maximum_percent         = 200
    propagate_tags                     = "SERVICE"
    enable_ecs_managed_tags            = true
  }
}

resource "aws_ecs_service" "web" {
  name                               = "web"
  cluster                            = local.svc_common.cluster
  task_definition                    = aws_ecs_task_definition.web.arn
  desired_count                      = var.web_min
  launch_type                        = local.svc_common.launch_type
  deployment_minimum_healthy_percent = local.svc_common.deployment_minimum_healthy_percent
  deployment_maximum_percent         = local.svc_common.deployment_maximum_percent
  health_check_grace_period_seconds  = 60
  wait_for_steady_state              = true
  propagate_tags                     = local.svc_common.propagate_tags
  enable_ecs_managed_tags            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.web.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = 3000
  }
  # the execution role must be able to read the secrets BEFORE the first task starts
  depends_on = [aws_lb_listener_rule.web, aws_iam_role_policy.exec_secrets, aws_iam_role_policy_attachment.exec, terraform_data.seed_cognito_secret]
  lifecycle { ignore_changes = [desired_count] } # owned by autoscaling
}

resource "aws_ecs_service" "api" {
  name                               = "api"
  cluster                            = local.svc_common.cluster
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.api_min
  launch_type                        = local.svc_common.launch_type
  deployment_minimum_healthy_percent = local.svc_common.deployment_minimum_healthy_percent
  deployment_maximum_percent         = local.svc_common.deployment_maximum_percent
  health_check_grace_period_seconds  = 60
  wait_for_steady_state              = true
  propagate_tags                     = local.svc_common.propagate_tags
  enable_ecs_managed_tags            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }
  service_registries {
    registry_arn = aws_service_discovery_service.api.arn
  }
  depends_on = [aws_lb_listener_rule.api, aws_iam_role_policy.exec_secrets, aws_iam_role_policy_attachment.exec, aws_iam_role_policy.api]
  lifecycle { ignore_changes = [desired_count] }
}

resource "aws_ecs_service" "worker" {
  name                               = "worker"
  cluster                            = local.svc_common.cluster
  task_definition                    = aws_ecs_task_definition.worker.arn
  desired_count                      = var.worker_min
  launch_type                        = local.svc_common.launch_type
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  wait_for_steady_state              = true
  propagate_tags                     = local.svc_common.propagate_tags
  enable_ecs_managed_tags            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }
  depends_on = [aws_iam_role_policy.exec_secrets, aws_iam_role_policy_attachment.exec, aws_iam_role_policy.worker, terraform_data.seed_llm_secrets]
  lifecycle { ignore_changes = [desired_count] }
}

############################ Autoscaling ############################

locals {
  scalable = {
    web    = { min = var.web_min, max = var.web_max, service = aws_ecs_service.web.name }
    api    = { min = var.api_min, max = var.api_max, service = aws_ecs_service.api.name }
    worker = { min = var.worker_min, max = var.worker_max, service = aws_ecs_service.worker.name }
  }
}

resource "aws_appautoscaling_target" "svc" {
  for_each           = local.scalable
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${each.value.service}"
  min_capacity       = var.paused ? 0 : each.value.min
  max_capacity       = var.paused ? 0 : each.value.max
  # on resume the database must be running BEFORE tasks come back
  depends_on = [terraform_data.db_power]
}

# web & api: keep average CPU near 60%
resource "aws_appautoscaling_policy" "cpu" {
  for_each           = { web = "web", api = "api" }
  name               = "${local.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.svc[each.key].resource_id
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}

# worker: one task per waiting job, up to worker_max (the LLM concurrency cap); scale back when the queue is idle.
resource "aws_appautoscaling_policy" "worker_out" {
  name               = "${local.name}-worker-out"
  policy_type        = "StepScaling"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.svc["worker"].resource_id
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_appautoscaling_policy" "worker_in" {
  name               = "${local.name}-worker-in"
  policy_type        = "StepScaling"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.svc["worker"].resource_id
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_backlog" {
  alarm_name          = "${local.name}-worker-backlog"
  alarm_description   = "Jobs are waiting: add a worker"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.jobs.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.worker_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "worker_idle" {
  alarm_name          = "${local.name}-worker-idle"
  alarm_description   = "No waiting and no in-flight jobs for 10 minutes: remove a worker"
  evaluation_periods  = 10
  threshold           = 0
  comparison_operator = "LessThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.worker_in.arn]

  metric_query {
    id          = "total"
    expression  = "visible + inflight"
    label       = "jobs waiting or running"
    return_data = true
  }
  metric_query {
    id = "visible"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      dimensions  = { QueueName = aws_sqs_queue.jobs.name }
      period      = 60
      stat        = "Maximum"
    }
  }
  metric_query {
    id = "inflight"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesNotVisible"
      dimensions  = { QueueName = aws_sqs_queue.jobs.name }
      period      = 60
      stat        = "Maximum"
    }
  }
}
