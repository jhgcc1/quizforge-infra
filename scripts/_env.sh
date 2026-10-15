# shared helpers for pause.sh / resume.sh / env-status.sh  (sourced, not executed)
# Lives in the quizforge-infra repository. Nothing here refers to the application code repository: the deployed version
# is read from ECS, the state bucket from TF_STATE_BUCKET / the repository variable / the bucket naming convention.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
INFRA_REPO="${INFRA_REPO:-jhgcc1/quizforge-infra}"
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
# The state bucket is never committed (it carries the account id). Order: TF_STATE_BUCKET, the repository variable of the
# same name, the naming convention of bootstrap (quizforge-tfstate-<account id>-<region>).
state_bucket() {
  if [ -n "${TF_STATE_BUCKET:-}" ]; then echo "$TF_STATE_BUCKET"; return; fi
  local b=""
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then b="$(gh variable get TF_STATE_BUCKET --repo "$INFRA_REPO" 2>/dev/null || true)"; fi
  [ -n "$b" ] || b="quizforge-tfstate-$(aws sts get-caller-identity --query Account --output text)-$AWS_REGION"
  echo "$b"
}
tf_init() {
  (cd "$TF_DIR" && terraform init -input=false -reconfigure \
    -backend-config="bucket=$(state_bucket)" -backend-config="key=quizforge/prod/terraform.tfstate" \
    -backend-config="region=$AWS_REGION" -backend-config="use_lockfile=true" -backend-config="encrypt=true" >/dev/null)
}
# Keep the GitHub variable PAUSED in sync so the deploy workflow respects the state (best effort).
# PAUSED_REPOS lists every repository whose pipeline must know (default: the infra repository; during the cutover window
# add the old one: PAUSED_REPOS="jhgcc1/quizforge-infra jhgcc1/quizforge").
set_paused_var() {
  local r
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    for r in ${PAUSED_REPOS:-$INFRA_REPO}; do gh variable set PAUSED --repo "$r" --body "$1" >/dev/null && echo "GitHub variable PAUSED=$1 ($r)"; done
  else echo "(gh not available: set the repo variable PAUSED=$1 yourself so the deploy workflow knows)"; fi
}
# who receives the CloudWatch alarms: the same repository variable the pipeline uses, so a local pause/resume never drops the subscription
if [ -z "${TF_VAR_alarm_email:-}" ] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  # the variable of the infra repository; until the cutover it may only exist in the code repository (LEGACY_VAR_REPO)
  for _r in "$INFRA_REPO" "${LEGACY_VAR_REPO:-jhgcc1/quizforge}"; do
    TF_VAR_alarm_email="$(gh variable get ALARM_EMAIL --repo "$_r" 2>/dev/null || true)"; [ -n "$TF_VAR_alarm_email" ] && break
  done
  export TF_VAR_alarm_email
fi
running_tasks() { aws ecs describe-services --cluster "$CLUSTER" --services web api worker scorer --query 'sum(services[].runningCount)' --output text; }
