# shared helpers for pause.sh / resume.sh / env-status.sh  (sourced, not executed)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"
export AWS_REGION="${AWS_REGION:-us-east-2}"
export PATH="$HOME/.npm-global/bin:$PATH"
CLUSTER="quizforge-prod"

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
need aws; need terraform; need jq
aws sts get-caller-identity >/dev/null 2>&1 || { echo "No valid AWS credentials. Set AWS_PROFILE (e.g. AWS_PROFILE=<your-profile>)." >&2; exit 1; }

# the image tag that is deployed right now: pausing/resuming must never change the running version
deployed_tag() {
  aws ecs describe-task-definition --task-definition quizforge-prod-api \
    --query 'taskDefinition.containerDefinitions[0].image' --output text | cut -d: -f2
}
deployed_web_tag() { # the web image has its own tag since the front end can be deployed alone
  aws ecs describe-task-definition --task-definition quizforge-prod-web \
    --query 'taskDefinition.containerDefinitions[0].image' --output text | cut -d: -f2
}
# Any terraform apply needs the real social login credentials (the identity providers are created from them), so read them
# from Secrets Manager here, exactly as the deploy does. Values are exported as TF_VAR_* and never printed.
load_social_secrets() {
  local p name idvar secretvar json
  for p in google:google_client_id:google_client_secret facebook:facebook_app_id:facebook_app_secret; do
    IFS=: read -r name idvar secretvar <<< "$p"
    json=$(aws secretsmanager get-secret-value --secret-id "quizforge/prod/$name-login" --query SecretString --output text 2>/dev/null) \
      || { echo "cannot read quizforge/prod/$name-login from Secrets Manager" >&2; exit 1; }
    export "TF_VAR_$idvar=$(jq -r .client_id <<< "$json")" "TF_VAR_$secretvar=$(jq -r .client_secret <<< "$json")"
  done
}
load_social_secrets
tf_init() { (cd "$TF_DIR" && [ -f backend.hcl ] && terraform init -input=false -reconfigure -backend-config=backend.hcl >/dev/null); }
set_paused_var() { # keep the GitHub variable in sync so the pipeline respects the state (best effort)
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then gh variable set PAUSED --repo jhgcc1/quizforge --body "$1" >/dev/null && echo "GitHub variable PAUSED=$1"; else echo "(gh not available: set the repo variable PAUSED=$1 yourself so the deploy pipeline knows)"; fi
}
# who receives the CloudWatch alarms: the same repository variable the pipeline uses, so a local pause/resume never drops the subscription
if [ -z "${TF_VAR_alarm_email:-}" ] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  TF_VAR_alarm_email="$(gh variable get ALARM_EMAIL --repo jhgcc1/quizforge 2>/dev/null || true)"; export TF_VAR_alarm_email
fi
running_tasks() { aws ecs describe-services --cluster "$CLUSTER" --services web api worker scorer --query 'sum(services[].runningCount)' --output text; }
