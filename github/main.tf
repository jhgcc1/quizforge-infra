terraform {
  required_version = ">= 1.10.0"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
  backend "s3" {}
}

# Authenticates with the GITHUB_TOKEN environment variable (e.g. GITHUB_TOKEN=$(gh auth token)).
provider "github" {
  owner = var.owner
}

variable "owner" {
  type    = string
  default = "jhgcc1"
}
variable "repository" {
  type    = string
  default = "quizforge"
}
variable "reviewer_user_id" {
  description = "Numeric GitHub user id that must approve production deployments"
  type        = number
}
variable "require_plan_check" {
  description = "Make the terraform-plan check mandatory (turn on after infra/bootstrap has been applied)"
  type        = bool
  default     = false
}
variable "aws_region" {
  type    = string
  default = "us-east-2"
}
variable "aws_plan_role_arn" { type = string }
variable "aws_deploy_role_arn" { type = string }
variable "tf_state_bucket" { type = string }

locals {
  # job names in .github/workflows/ci.yml: every one must be green before a PR can merge
  required_checks = concat(
    ["quality", "integration", "migrations", "e2e", "docker-build", "terraform-validate", "secrets-scan", "promptfoo"],
    var.require_plan_check ? ["terraform-plan"] : [],
  )
}

# ---------------------------------------------------------------- repository settings
import {
  to = github_repository.this
  id = var.repository
}

#trivy:ignore:AVD-GIT-0001 deliberate: public repo = free branch protection/rulesets, and nothing sensitive is committed (gitleaks gate)
#trivy:ignore:AVD-GIT-0003 alerts are enabled by the github_repository_vulnerability_alerts resource below (the inline attribute is deprecated)
resource "github_repository" "this" {
  name                        = var.repository
  description                 = "QuizForge: AI agent that generates and scores quizzes from a Markdown README (LangGraph, Next.js, AWS Fargate)"
  visibility                  = "public"
  has_issues                  = true
  allow_squash_merge          = true
  allow_merge_commit          = false
  allow_rebase_merge          = false
  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "PR_BODY"
  delete_branch_on_merge      = true

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
}

resource "github_repository_vulnerability_alerts" "this" {
  repository = github_repository.this.name
  enabled    = true
}

# ---------------------------------------------------------------- main is only changed through a green pull request
resource "github_repository_ruleset" "main" {
  name        = "protect-main"
  repository  = github_repository.this.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # no bypass_actors: not even the repository owner can push to main directly

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      required_approving_review_count   = 0 # sole maintainer: the gate is the checks, not a second human
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true # the branch must be up to date with main before merging
      dynamic "required_check" {
        for_each = local.required_checks
        content {
          context = required_check.value
        }
      }
    }
  }
}

# ---------------------------------------------------------------- production deployments need a human click
resource "github_repository_environment" "production" {
  repository          = github_repository.this.name
  environment         = "production"
  prevent_self_review = false # the only maintainer approves their own deploys; the checks already ran
  reviewers {
    users = [var.reviewer_user_id]
  }
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main_only" {
  repository     = github_repository.this.name
  environment    = github_repository_environment.production.environment
  branch_pattern = "main"
}

# ---------------------------------------------------------------- non-secret pipeline configuration
resource "github_actions_variable" "vars" {
  for_each = {
    AWS_REGION          = var.aws_region
    AWS_PLAN_ROLE_ARN   = var.aws_plan_role_arn
    AWS_DEPLOY_ROLE_ARN = var.aws_deploy_role_arn
    TF_STATE_BUCKET     = var.tf_state_bucket
  }
  repository    = github_repository.this.name
  variable_name = each.key
  value         = each.value
}

# Holds the LLM/Langfuse credentials used by the evaluation workflow (values set by hand with `gh secret set --env llm-eval`,
# never through Terraform, so they stay out of state). Only `main` may use them.
resource "github_repository_environment" "llm_eval" {
  repository  = github_repository.this.name
  environment = "llm-eval"
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "llm_eval_main" {
  repository     = github_repository.this.name
  environment    = github_repository_environment.llm_eval.environment
  branch_pattern = "main"
}
