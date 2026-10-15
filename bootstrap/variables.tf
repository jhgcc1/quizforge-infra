variable "project" {
  type    = string
  default = "quizforge"
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "github_repo" {
  description = "owner/name of the application CODE repository (until the cutover it may still assume the plan and deploy roles; it may push images)"
  type        = string
  default     = "jhgcc1/quizforge"
}

variable "create_oidc_provider" {
  description = "The GitHub OIDC provider is account-wide: set false if the account already has one"
  type        = bool
  default     = true
}

variable "github_owner_id" {
  description = "Numeric id of the GitHub owner (gh api users/<owner> --jq .id). New repositories put it in the OIDC subject."
  type        = number
  default     = 46584477
}

variable "github_repo_id" {
  description = "Numeric id of the repository (gh api repos/<owner>/<repo> --jq .id)"
  type        = number
  default     = 1409267817
}

variable "infra_repo" {
  description = "owner/name of the infrastructure repository: its workflows assume the plan role (PRs, branches) and the deploy role (environment production)"
  type        = string
  default     = "jhgcc1/quizforge-infra"
}

variable "infra_repo_id" {
  description = "Numeric id of the infra repository (gh api repos/jhgcc1/quizforge-infra --jq .id)"
  type        = number
  default     = 1420996676
}

variable "web_repo" {
  description = "owner/name of the front end repository: its main branch may push the web image (publish role)"
  type        = string
  default     = "jhgcc1/quizforge-web"
}

variable "web_repo_id" {
  description = "Numeric id of the front end repository (gh api repos/jhgcc1/quizforge-web --jq .id)"
  type        = number
  default     = 1419364905
}

variable "keep_code_repo_trust" {
  description = "Keep the code repository in the plan and deploy trust policies. true until the cutover to the infra repository, then false."
  type        = bool
  default     = true
}
