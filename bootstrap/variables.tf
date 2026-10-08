variable "project" {
  type    = string
  default = "quizforge"
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "github_repo" {
  description = "owner/name of the repository allowed to assume the pipeline roles"
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
