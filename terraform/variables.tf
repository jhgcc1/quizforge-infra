variable "project" {
  type    = string
  default = "quizforge"
}
variable "environment" {
  type    = string
  default = "prod"
}
variable "region" {
  type    = string
  default = "us-east-2"
}
variable "image_tag" {
  description = "Image tag (git sha) deployed for web, api and worker"
  type        = string
}
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

# --- capacity ---
variable "web_min" {
  type    = number
  default = 2
}
variable "web_max" {
  type    = number
  default = 6
}
variable "api_min" {
  type    = number
  default = 2
}
variable "api_max" {
  type    = number
  default = 6
}
variable "worker_min" {
  type    = number
  default = 1
}
variable "worker_max" {
  description = "Hard cap on concurrent generations (one job per task): protects the LLM rate limit"
  type        = number
  default     = 4
}
variable "cpu_architecture" {
  description = "ARM64 (Graviton, ~20% cheaper; what the pipeline builds) or X86_64 (for images built on an amd64 machine)"
  type        = string
  default     = "ARM64"
  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}
variable "task_cpu" {
  type    = number
  default = 512
}
variable "task_memory" {
  type    = number
  default = 1024
}

# --- data & safety ---
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}
variable "db_backup_retention_days" {
  description = "Automated backup retention. AWS free-plan accounts are capped at 1; use 7+ on a paid account."
  type        = number
  default     = 7
}
variable "db_multi_az" {
  type    = bool
  default = false
}
variable "deletion_protection" {
  description = "Protects RDS, ALB and Cognito from accidental destroy. Set true for anything long-lived."
  type        = bool
  default     = false
}

# --- app config ---
variable "minimax_model" {
  type    = string
  default = "MiniMax-M2.7"
}
variable "minimax_judge_model" {
  description = "Model that judges generated quizzes. Keep it different from minimax_model to avoid self-preference bias."
  type        = string
  default     = "MiniMax-M3"
}
variable "default_source_url" {
  type    = string
  default = "https://github.com/pipecat-ai/pipecat/blob/main/README.md"
}
variable "daily_quiz_quota" {
  type    = number
  default = 10
}
variable "enable_cli_client" {
  description = "Second Cognito app client with USER_PASSWORD_AUTH so REST consumers can obtain a token with the AWS CLI"
  type        = bool
  default     = true
}

# --- alerting & cost ---
variable "alarm_email" {
  description = "Receives CloudWatch alarms (empty = alarms exist but nobody is subscribed)"
  type        = string
  default     = ""
}
variable "monthly_budget_usd" {
  type    = number
  default = 200
}
variable "daily_llm_cost_alarm_usd" {
  type    = number
  default = 5
}
variable "min_quality_score" {
  description = "Alarm when the hourly average quiz quality (0..1) drops below this"
  type        = number
  default     = 0.6
}
