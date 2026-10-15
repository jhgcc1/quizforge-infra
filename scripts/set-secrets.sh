#!/usr/bin/env bash
# Stores the LLM and Langfuse credentials in AWS Secrets Manager, read from the local .env.
# Values go straight to AWS: they never enter Terraform state, git, or the pipeline.
# The file is the .env of the application code checkout (or any file with the same keys): ENV_FILE=/path/to/.env scripts/set-secrets.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-./.env}"
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE: set ENV_FILE=/path/to/.env (the code repository .env)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${MINIMAX_API_KEY:?missing in $ENV_FILE}" "${LANGFUSE_PUBLIC_KEY:?missing in $ENV_FILE}" "${LANGFUSE_SECRET_KEY:?missing in $ENV_FILE}"
NAME="${NAME_PREFIX:-quizforge-prod}"
put() { # <secret-id> <json>
  aws secretsmanager put-secret-value --secret-id "$1" --secret-string "$2" --query VersionId --output text >/dev/null
  echo "updated $1"
}
put "$NAME/llm" "$(jq -nc --arg k "$MINIMAX_API_KEY" '{MINIMAX_API_KEY:$k}')"
put "$NAME/langfuse" "$(jq -nc --arg p "$LANGFUSE_PUBLIC_KEY" --arg s "$LANGFUSE_SECRET_KEY" '{LANGFUSE_PUBLIC_KEY:$p,LANGFUSE_SECRET_KEY:$s}')"
