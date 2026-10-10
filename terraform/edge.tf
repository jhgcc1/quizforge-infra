############################ Load balancer ############################
# Public ALB, but its security group only admits CloudFront, and the listener also demands a secret header.
# (Without a custom domain there is no certificate for the ALB, so CloudFront -> ALB is HTTP inside AWS.)

#trivy:ignore:AVD-AWS-0053 deliberate: internet-facing, but its security group admits ONLY the CloudFront origin-facing prefix list and every rule demands the secret x-origin-verify header
resource "aws_lb" "main" {
  count                      = var.paused ? 0 : 1 # paused: the load balancer (~US$16/month + 2 public IPv4 addresses) is deleted and recreated on resume
  name                       = local.name
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  idle_timeout               = 60
}

resource "aws_lb_target_group" "web" {
  name                 = "${local.name}-web"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30
  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_target_group" "api" {
  name                 = "${local.name}-api"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30
  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

#trivy:ignore:AVD-AWS-0054 deliberate: no custom domain means no certificate for the ALB; viewers always use HTTPS to CloudFront, and this hop never leaves AWS. Terminate TLS here once a domain exists
resource "aws_lb_listener" "http" {
  count             = var.paused ? 0 : 1
  load_balancer_arn = aws_lb.main[0].arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "api" {
  count        = var.paused ? 0 : 1
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
  condition {
    http_header {
      http_header_name = "x-origin-verify"
      values           = [random_password.origin_verify.result]
    }
  }
  condition {
    path_pattern { values = ["/v1/*", "/docs", "/openapi.json"] }
  }
}

resource "aws_lb_listener_rule" "web" {
  count        = var.paused ? 0 : 1
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 20
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
  condition {
    http_header {
      http_header_name = "x-origin-verify"
      values           = [random_password.origin_verify.result]
    }
  }
  condition {
    path_pattern { values = ["/*"] }
  }
}

############################ WAF (CloudFront scope, us-east-1) ############################

resource "aws_wafv2_web_acl" "main" {
  # paused: deleted (about US$8/month) and recreated on resume. keep_waf is only used by scripts/pause.sh: phase 1 lets CloudFront
  # release the web ACL (keep_waf=true), phase 2 deletes it. Terraform does not order "update the distribution" before "delete the
  # web ACL" by itself, and AWS refuses to delete a web ACL that CloudFront still uses (WAFAssociatedItemException).
  count    = var.paused && !var.keep_waf ? 0 : 1
  provider = aws.us_east_1
  name     = local.name
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 1000 # requests per 5 minutes per client IP
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = { common = [2, "AWSManagedRulesCommonRuleSet"], bad-inputs = [3, "AWSManagedRulesKnownBadInputsRuleSet"] }
    content {
      name     = rule.value[1]
      priority = rule.value[0]
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          name        = rule.value[1]
          vendor_name = "AWS"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

############################ CloudFront ############################

locals {
  # for alarms and the dashboard (they stay; with no load balancer they simply have no data)
  alb_arn_suffix = try(aws_lb.main[0].arn_suffix, "paused")

  # AWS managed policies
  cache_disabled    = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
  cache_optimized   = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
  origin_all_viewer = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer (forwards Host, cookies, headers)
  all_methods       = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
  api_paths         = ["/v1/*", "/docs", "/openapi.json"]
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = local.name
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  web_acl_id      = var.paused ? null : aws_wafv2_web_acl.main[0].arn

  origin {
    origin_id = "alb"
    # paused: there is no load balancer; the origin is a placeholder (the distribution itself stays: it costs nothing idle and keeps its
    # domain name, which the Cognito callback URLs use). On resume the new load balancer name replaces it.
    domain_name = var.paused ? "alb.paused.invalid" : aws_lb.main[0].dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }
    custom_header {
      name  = "x-origin-verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = local.all_methods
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = local.cache_disabled
    origin_request_policy_id = local.origin_all_viewer
  }

  ordered_cache_behavior {
    path_pattern             = "/_next/static/*"
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = local.cache_optimized
    origin_request_policy_id = local.origin_all_viewer
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.api_paths
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "alb"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = local.all_methods
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = local.cache_disabled
      origin_request_policy_id = local.origin_all_viewer
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
