# The infrastructure repository itself (this one): settings, protection of main, the `production` environment with its human
# approval, and the non-secret configuration read by .github/workflows/*.yml. Same rules as the code repository.

import {
  to = github_repository.infra
  id = var.infra_repository
}

#trivy:ignore:AVD-GIT-0001 deliberate: public repo = free branch protection/rulesets, and nothing sensitive is committed (gitleaks gate, account id and state bucket are run-time inputs)
#trivy:ignore:AVD-GIT-0003 alerts are enabled by the github_repository_vulnerability_alerts resource below (the inline attribute is deprecated)
resource "github_repository" "infra" {
  name                        = var.infra_repository
  description                 = "Infrastructure (Terraform on AWS), deploy and operations for QuizForge"
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

resource "github_repository_vulnerability_alerts" "infra" {
  repository = github_repository.infra.name
  enabled    = true
}

locals {
  # job names in .github/workflows/ci.yml of the infra repository: every one must be green before a PR can merge
  infra_required_checks = ["terraform-validate", "trivy-config", "secrets-scan", "workflow-lint", "terraform-plan"]
}

resource "github_repository_ruleset" "infra_main" {
  name        = "protect-main"
  repository  = github_repository.infra.name
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
      required_approving_review_count   = 0 # sole maintainer: the gate is the checks, plus the human approval of the production environment
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true
      dynamic "required_check" {
        for_each = local.infra_required_checks
        content {
          context = required_check.value
        }
      }
    }
  }
}

# Production deploys (and only those) need a human click; the deploy IAM role trusts exactly this environment of this repository.
resource "github_repository_environment" "infra_production" {
  repository          = github_repository.infra.name
  environment         = "production"
  prevent_self_review = false # the only maintainer approves their own deploys
  reviewers {
    users = [var.reviewer_user_id]
  }
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "infra_main_only" {
  repository     = github_repository.infra.name
  environment    = github_repository_environment.infra_production.environment
  branch_pattern = "main"
}

resource "github_actions_variable" "infra_vars" {
  for_each = {
    AWS_REGION          = var.aws_region
    AWS_PLAN_ROLE_ARN   = var.aws_plan_role_arn
    AWS_DEPLOY_ROLE_ARN = var.aws_deploy_role_arn
    TF_STATE_BUCKET     = var.tf_state_bucket
    ALARM_EMAIL         = var.alarm_email
  }
  repository    = github_repository.infra.name
  variable_name = each.key
  value         = each.value
}

# PAUSED is written by scripts/pause.sh and scripts/resume.sh; Terraform only creates it.
resource "github_actions_variable" "infra_paused" {
  repository    = github_repository.infra.name
  variable_name = "PAUSED"
  value         = var.initial_paused
  lifecycle { ignore_changes = [value] }
}

# The code repository's publish job pushes the images to ECR through this role (see docs/DESIGN.md). Created only after bootstrap/ has been applied.
resource "github_actions_variable" "code_publish_role" {
  count         = var.aws_publish_role_arn == "" ? 0 : 1
  repository    = github_repository.this.name
  variable_name = "AWS_PUBLISH_ROLE_ARN"
  value         = var.aws_publish_role_arn
}
