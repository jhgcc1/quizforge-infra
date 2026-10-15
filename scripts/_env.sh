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
tf_init() { (cd "$TF_DIR" && [ -f backend.hcl ] && terraform init -input=false -reconfigure -backend-config=backend.hcl >/dev/null); }
set_paused_var() { # keep the GitHub variable in sync so the pipeline respects the state (best effort)
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then gh variable set PAUSED --repo jhgcc1/quizforge --body "$1" >/dev/null && echo "GitHub variable PAUSED=$1"; else echo "(gh not available: set the repo variable PAUSED=$1 yourself so the deploy pipeline knows)"; fi
}
# who receives the CloudWatch alarms: the same repository variable the pipeline uses, so a local pause/resume never drops the subscription
if [ -z "${TF_VAR_alarm_email:-}" ] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  TF_VAR_alarm_email="$(gh variable get ALARM_EMAIL --repo jhgcc1/quizforge 2>/dev/null || true)"; export TF_VAR_alarm_email
fi
running_tasks() { aws ecs describe-services --cluster "$CLUSTER" --services web api worker scorer --query 'sum(services[].runningCount)' --output text; }
