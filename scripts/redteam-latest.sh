#!/usr/bin/env bash
# Print a pre-signed link to the newest nightly red team report (a private S3 object), and a short text summary.
#   scripts/redteam-latest.sh              the newest run (redteam/latest/report.html)
#   scripts/redteam-latest.sh RUN_ID       one run, for example 2026-10-14T06-00-12Z
#   scripts/redteam-latest.sh --list       the last runs
# Needs the AWS CLI and credentials that can read the reports bucket and use its KMS key (an admin or the deploy role).
# The link works as long as YOUR credentials do (an SSO session: a few hours at most), up to 7 days.
set -euo pipefail
export AWS_REGION="${AWS_REGION:-us-east-2}"
command -v aws >/dev/null || { echo "missing tool: aws" >&2; exit 1; }
account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || { echo "No valid AWS credentials. Set AWS_PROFILE." >&2; exit 1; }
bucket="${REPORT_BUCKET:-quizforge-prod-reports-${account}}"

if [ "${1:-}" = "--list" ]; then
  aws s3api list-objects-v2 --bucket "$bucket" --prefix redteam/ --delimiter / --query 'CommonPrefixes[].Prefix' --output text | tr '\t' '\n' | grep -v '/latest/$' | tail -20
  exit 0
fi

run="${1:-latest}"
key="redteam/${run}/report.html"
aws s3api head-object --bucket "$bucket" --key "$key" >/dev/null 2>&1 || { echo "No report at s3://${bucket}/${key}. List the runs with: scripts/redteam-latest.sh --list" >&2; exit 1; }

if command -v jq >/dev/null; then
  aws s3 cp "s3://${bucket}/redteam/${run}/summary.json" - 2>/dev/null \
    | jq -r '"run \(.run.runId): \(.cases) cases, \(.rejectedBeforeModel) rejected before the model, \(.rejectedByRails) by the output rails, \(.validQuiz) valid quiz, \(.leaked) LEAKED, \(.otherFailures) other failures"' >&2 || true
fi
aws s3 presign "s3://${bucket}/${key}" --expires-in 604800
