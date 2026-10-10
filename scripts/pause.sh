#!/usr/bin/env bash
# Pause the AWS environment: stops most of the bill, keeps ALL data/config. Undo with scripts/resume.sh.
# Usage: AWS_PROFILE=... scripts/pause.sh
. "$(dirname "$0")/_env.sh"
tf_init
TAG=$(deployed_tag)
echo "Pausing quizforge-prod (deployed version ${TAG:0:7} is kept)..."
set_paused_var true
(cd "$TF_DIR" && terraform apply -input=false -auto-approve -var "image_tag=$TAG" -var paused=true | grep -E "Apply complete|Error|stopping" )

echo "waiting for the tasks to drain..."
for i in $(seq 1 40); do [ "$(running_tasks)" = "0" ] && break; sleep 10; done
echo "running tasks: $(running_tasks)"
"$(dirname "$0")/env-status.sh"
cat <<MSG

PAUSED. Still billed (roughly US\$0.3/day, about US\$8/month): RDS storage, KMS keys, secrets, logs, ECR images.
  * The load balancer and the WAF are deleted while paused (resume recreates them; the CloudFront update takes ~10 minutes).
  * AWS restarts a stopped RDS by itself after 7 days: if you stay paused longer, run this script again.
  * The deploy pipeline refuses to run while PAUSED=true.
  * Bring everything back with:  AWS_PROFILE=... scripts/resume.sh
MSG
