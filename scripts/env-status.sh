#!/usr/bin/env bash
# One-screen status of the environment and what it is costing right now.
. "$(dirname "$0")/_env.sh"
db=$(aws rds describe-db-instances --db-instance-identifier quizforge-prod --query 'DBInstances[0].DBInstanceStatus' --output text)
nat=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=quizforge-prod Name=state,Values=available,pending --query 'length(NatGateways)' --output text)
echo "--- quizforge-prod ---"
aws ecs describe-services --cluster "$CLUSTER" --services web api worker --query 'services[].[serviceName,runningCount,desiredCount]' --output text | awk '{printf "  ecs %-7s running=%s desired=%s\n",$1,$2,$3}'
echo "  rds quizforge-prod: $db"
echo "  nat gateway: $([ "$nat" -gt 0 ] && echo present || echo absent)"
echo "  EventBridge sweeper: $(aws scheduler get-schedule --name quizforge-prod-sweeper --query State --output text)"
if [ "$db" = "stopped" ] && [ "$nat" = "0" ] && [ "$(running_tasks)" = "0" ]; then echo "  => PAUSED (about US\$1-2/day)"; else echo "  => RUNNING (about US\$5/day)"; fi
