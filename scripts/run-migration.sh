#!/usr/bin/env bash
# Runs the database migration as a one-off Fargate task and fails unless it exits 0.
# Usage: scripts/run-migration.sh   (run after `terraform init`; reads the task wiring from terraform outputs)
set -euo pipefail
cd "$(dirname "$0")/../infra/terraform"

out=$(terraform output -json migrate_run_task)
cluster=$(jq -r .cluster <<<"$out"); td=$(jq -r .task_definition <<<"$out")
subnets=$(jq -r '.subnets | join(",")' <<<"$out"); sg=$(jq -r .security_group <<<"$out")

task=$(aws ecs run-task --cluster "$cluster" --task-definition "$td" --launch-type FARGATE --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)
if [ -z "$task" ] || [ "$task" = "None" ]; then echo "::error::could not start the migration task"; exit 1; fi
echo "migration task: $task"

aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task"
desc=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" --query 'tasks[0].containers[0]' --output json)
code=$(jq -r '.exitCode // "none"' <<<"$desc")

# show what the task printed, whatever the outcome
stream="migrate/migrate/${task##*/}"
aws logs get-log-events --log-group-name "/quizforge/prod/migrate" --log-stream-name "$stream" --query 'events[].message' --output text 2>/dev/null | tail -20 || true

if [ "$code" != "0" ]; then
  echo "::error::migration failed (exit=$code, reason=$(jq -r '.reason // "n/a"' <<<"$desc"))"
  exit 1
fi
echo "migration applied successfully"
