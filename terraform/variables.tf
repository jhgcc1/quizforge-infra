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
  description = "Image tag (commit sha) of the web, api, worker and redteam images (the scorer, sweeper and migrate tasks use the worker image)"
  type        = string
}
variable "web_image_tag" {
  description = "Image tag of the web image only. Empty = same as image_tag. A front-end-only deploy sets it and keeps image_tag at what is running."
  type        = string
  default     = ""
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
variable "scorer_min" {
  description = "Scorer service (judges saved quizzes off the request path). 1 keeps scores arriving within seconds."
  type        = number
  default     = 1
}
variable "scorer_max" {
  type    = number
  default = 2
}
variable "worker_cpu" {
  description = "Generation worker. 1 vCPU: Fargate then allows 2 to 8 GB, and the semantic detector scans a document in a few seconds instead of tens"
  type        = number
  default     = 1024
}
variable "worker_memory" {
  description = "Generation worker with Llama Prompt Guard 2 loaded (1.1 GB of weights): measured peak about 2.1 GB, so 4 GB leaves room for the Node heap and long documents. About $20 a month more per task than 0.5 vCPU / 1 GB (ARM64, us-east-1)"
  type        = number
  default     = 4096
}
variable "injection_detector" {
  description = "Semantic prompt-injection detector in the generation worker: off | flag (record a finding, the document goes on) | block (reject). The worker image must be the runtime-detector target, which contains the model."
  type        = string
  default     = "flag"
  validation {
    condition     = contains(["off", "flag", "block"], var.injection_detector)
    error_message = "injection_detector must be off, flag or block."
  }
}
variable "scorer_cpu" {
  description = "The scorer only waits for the LLM, so it is small (0.25 vCPU is about $7 a month)"
  type        = number
  default     = 256
}
variable "scorer_memory" {
  type    = number
  default = 512
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
  description = "Model that judges every generated quiz in production. Set it to the same model the CI evaluation uses (MiniMax-M3, median of JUDGE_SAMPLES=3 parallel runs) so that production and CI scores are produced by the same method. Empty = the generator judges itself (self-preference bias)."
  type        = string
  default     = ""
}
variable "default_source_url" {
  type    = string
  default = "https://github.com/pipecat-ai/pipecat/blob/main/README.md"
}
variable "daily_quiz_quota" {
  type    = number
  default = 10
}
variable "allow_self_signup" {
  description = "Anyone can create an account (e-mail + password, e-mail verified). false = only an administrator creates users."
  type        = bool
  default     = true
}
variable "google_enabled" {
  description = "Create the Google identity provider. The client id and secret are read from AWS Secrets Manager (quizforge/prod/google-login) by the deploy; plan and drift runs use placeholders (provider_details is ignored after creation)."
  type        = bool
  default     = false
}
variable "facebook_enabled" {
  description = "Create the Facebook identity provider. The app id and secret are read from AWS Secrets Manager (quizforge/prod/facebook-login) by the deploy; plan and drift runs use placeholders (provider_details is ignored after creation)."
  type        = bool
  default     = false
}
variable "google_client_id" {
  description = "Google OAuth client id, from Secrets Manager at deploy time. A public identifier, not a secret."
  type        = string
  default     = "placeholder"
}
variable "google_client_secret" {
  description = "Google OAuth client secret, from Secrets Manager at deploy time"
  type        = string
  default     = "placeholder"
  sensitive   = true
}
variable "facebook_app_id" {
  description = "Facebook app id, from Secrets Manager at deploy time. A public identifier, not a secret."
  type        = string
  default     = "placeholder"
}
variable "facebook_app_secret" {
  description = "Facebook app secret, from Secrets Manager at deploy time"
  type        = string
  default     = "placeholder"
  sensitive   = true
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
variable "critical_quality_score" {
  description = "Alarm when a SINGLE quiz scores below this (0..1), whatever the hourly average is"
  type        = number
  default     = 0.4
}
variable "min_quality_score" {
  description = "Alarm when the hourly average quiz quality (0..1) drops below this"
  type        = number
  default     = 0.6
}

variable "paused" {
  description = "Pause the environment to stop most of the bill while keeping ALL data and configuration: ECS services scale to 0, the RDS instance is stopped, the NAT gateway is removed and the sweeper schedule is disabled. Resume = apply with paused=false (scripts/pause.sh and scripts/resume.sh do both)."
  type        = bool
  default     = false
}

variable "keep_waf" {
  description = "Only for scripts/pause.sh (phase 1 of a pause): keep the web ACL while CloudFront is updated to stop using it. Leave false."
  type        = bool
  default     = false
}

variable "rejected_documents_alarm" {
  description = "Documents rejected (hidden text, unsupported language) in 15 minutes that raise the documents-rejected-spike alarm."
  type        = number
  default     = 5
}

variable "flagged_documents_alarm" {
  description = "Documents flagged for an instruction aimed at a model in 1 hour that raise the injection-flagged-spike alarm."
  type        = number
  default     = 10
}

variable "enable_local_dev_client" {
  description = "Create a separate Cognito app client whose only redirect is http://localhost:13000, to try the real login (Cognito, Google, Facebook) from the local stack (scripts/local-cognito.sh). Off by default."
  type        = bool
  default     = false
}

# --- nightly red team (redteam.tf) ---
variable "redteam_enabled" {
  description = "Run the nightly red team task (a separate Fargate task, not a service) and watch it with two alarms. false = the schedule is disabled and the alarms are removed; the bucket and the reports stay."
  type        = bool
  default     = true
}
variable "redteam_schedule" {
  description = "EventBridge Scheduler expression (UTC) of the nightly red team run"
  type        = string
  default     = "cron(0 6 * * ? *)"
}
variable "redteam_cpu" {
  description = "Red team task CPU. 2 vCPU: Fargate then allows 4 to 16 GB; the semantic detector (Llama Prompt Guard 2) and the parallel cases need the room"
  type        = number
  default     = 2048
}
variable "redteam_memory" {
  description = "Red team task memory in MB (the detector model is 1.1 GB; 4 GB like the worker)"
  type        = number
  default     = 4096
}
variable "redteam_num_tests" {
  description = "Fresh attack texts per intent each night. The suite has 32 intents and 2 cases per text, so 10 means about 640 tests. Each case that reaches the model costs one generation"
  type        = number
  default     = 10
  validation {
    condition     = var.redteam_num_tests >= 1 && var.redteam_num_tests <= 100 && var.redteam_num_tests == floor(var.redteam_num_tests)
    error_message = "redteam_num_tests must be a whole number from 1 to 100."
  }
}
