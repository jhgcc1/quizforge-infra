#!/usr/bin/env bash
# Resume a paused environment: recreates the NAT gateway, starts the database and scales the services back up.
# Usage: AWS_PROFILE=... scripts/resume.sh        (takes about 10 minutes, mostly the database start)
. "$(dirname "$0")/_env.sh"
tf_init
TAG=$(deployed_tag)
echo "Resuming quizforge-prod (version ${TAG:0:7})..."
(cd "$TF_DIR" && terraform apply -input=false -auto-approve -var "image_tag=$TAG" -var paused=false | grep -E "Apply complete|Error|starting")
set_paused_var false

echo "waiting for web, api and worker to be healthy..."
for i in $(seq 1 60); do
  ok=$(aws ecs describe-services --cluster "$CLUSTER" --services web api worker --query 'length(services[?runningCount>=`1` && runningCount==desiredCount && deployments[0].rolloutState==`COMPLETED`])' --output text)
  [ "$ok" = "3" ] && break; sleep 10
done
APP=$(cd "$TF_DIR" && terraform output -raw app_url)
for path in / /openapi.json; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$APP$path"); echo "  $APP$path -> $code"
done
"$(dirname "$0")/env-status.sh"
echo; echo "RESUMED: $APP"
