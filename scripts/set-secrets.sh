#!/usr/bin/env bash
# Stores the LLM and Langfuse credentials in AWS Secrets Manager, read from the local .env.
# Values go straight to AWS: they never enter Terraform state, git, or the pipeline.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${MINIMAX_API_KEY:?missing in .env}" "${LANGFUSE_PUBLIC_KEY:?missing in .env}" "${LANGFUSE_SECRET_KEY:?missing in .env}"
NAME="${NAME_PREFIX:-quizforge-prod}"
put() { # <secret-id> <json>
  aws secretsmanager put-secret-value --secret-id "$1" --secret-string "$2" --query VersionId --output text >/dev/null
  echo "updated $1"
}
put "$NAME/llm" "$(jq -nc --arg k "$MINIMAX_API_KEY" '{MINIMAX_API_KEY:$k}')"
put "$NAME/langfuse" "$(jq -nc --arg p "$LANGFUSE_PUBLIC_KEY" --arg s "$LANGFUSE_SECRET_KEY" '{LANGFUSE_PUBLIC_KEY:$p,LANGFUSE_SECRET_KEY:$s}')"
