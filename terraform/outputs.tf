output "app_url" {
  description = "Public HTTPS URL of the application"
  value       = local.app_url
}
output "api_docs_url" {
  value = "${local.app_url}/docs"
}
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}
output "cognito_cli_client_id" {
  value = var.enable_cli_client ? aws_cognito_user_pool_client.cli[0].id : null
}
output "jobs_queue_url" {
  value = aws_sqs_queue.jobs.url
}
output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}
output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}
output "secret_ids" {
  description = "Secrets to populate with scripts/set-secrets.sh"
  value       = { llm = aws_secretsmanager_secret.llm.name, langfuse = aws_secretsmanager_secret.langfuse.name }
}
output "dashboard" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
# Everything the pipeline needs to run the migration as a one-off Fargate task before updating services.
output "migrate_run_task" {
  value = {
    cluster         = aws_ecs_cluster.main.name
    task_definition = aws_ecs_task_definition.migrate.family
    subnets         = aws_subnet.app[*].id
    security_group  = aws_security_group.worker.id
  }
}

output "alb_dns" {
  description = "Used by the deploy smoke test to prove the ALB refuses traffic that bypasses CloudFront"
  value       = aws_lb.main.dns_name
}
