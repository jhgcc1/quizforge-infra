data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# --- ALB: reachable only from CloudFront's origin-facing IP ranges ---
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB: CloudFront origin-facing only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-alb" }
}
resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "CloudFront to ALB"
}

resource "aws_security_group" "web" {
  name        = "${local.name}-web"
  description = "Next.js tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-web" }
}
resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "api" {
  name        = "${local.name}-api"
  description = "API tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-api" }
}
resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "api_from_web" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "BFF to API over Cloud Map DNS"
}

resource "aws_security_group" "worker" {
  name        = "${local.name}-worker"
  description = "LLM worker and one-off tasks: egress only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-worker" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "RDS: only the app tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-db" }
}
resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  for_each                     = { api = aws_security_group.api.id, worker = aws_security_group.worker.id }
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "${each.key} to Postgres"
}

# Tasks need outbound HTTPS (ECR, SQS, Secrets Manager, Cognito, MiniMax, Langfuse, GitHub) and the DB.
resource "aws_vpc_security_group_egress_rule" "all_out" {
  for_each          = { alb = aws_security_group.alb.id, web = aws_security_group.web.id, api = aws_security_group.api.id, worker = aws_security_group.worker.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "outbound"
}
