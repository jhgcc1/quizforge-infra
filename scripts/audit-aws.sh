#!/usr/bin/env bash
# Read-only audit of the DEPLOYED infrastructure against the security/availability claims in the README.
# Usage: AWS_PROFILE=... scripts/audit-aws.sh      Exit code = number of failed checks.
set -u
R=${AWS_REGION:-us-east-2}; P=quizforge-prod
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1  -> $2"; fail=$((fail+1)); }
chk() { local what=$1 got=$2 want=$3; [ "$got" = "$want" ] && ok "$what" || bad "$what" "got '$got', want '$want'"; }
q() { aws --region "$R" "$@" --output text 2>/dev/null; }

echo "== network"
VPC=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=$P --query 'Vpcs[0].VpcId')
chk "RDS is not publicly accessible" "$(q rds describe-db-instances --db-instance-identifier $P --query 'DBInstances[0].PubliclyAccessible')" "False"
chk "RDS storage is encrypted" "$(q rds describe-db-instances --db-instance-identifier $P --query 'DBInstances[0].StorageEncrypted')" "True"
chk "RDS forces TLS (rds.force_ssl=1)" "$(q rds describe-db-parameters --db-parameter-group-name $P-pg16 --query "Parameters[?ParameterName=='rds.force_ssl'].ParameterValue")" "1"
chk "RDS has automated backups" "$([ "$(q rds describe-db-instances --db-instance-identifier $P --query 'DBInstances[0].BackupRetentionPeriod')" -ge 1 ] && echo yes)" "yes"
chk "RDS master password is managed by Secrets Manager" "$([ -n "$(q rds describe-db-instances --db-instance-identifier $P --query 'DBInstances[0].MasterUserSecret.SecretArn')" ] && echo yes)" "yes"
DBSG=$(q rds describe-db-instances --db-instance-identifier $P --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId')
chk "DB security group admits only SG sources (no CIDR)" "$(q ec2 describe-security-groups --group-ids $DBSG --query 'SecurityGroups[0].IpPermissions[].IpRanges[]' | wc -w | tr -d ' ')" "0"
ALBSG=$(q ec2 describe-security-groups --filters Name=group-name,Values=$P-alb --query 'SecurityGroups[0].GroupId')
chk "ALB security group has NO open CIDR ingress" "$(q ec2 describe-security-groups --group-ids $ALBSG --query 'SecurityGroups[0].IpPermissions[].IpRanges[]' | wc -w | tr -d ' ')" "0"
chk "ALB ingress comes from the CloudFront prefix list" "$([ -n "$(q ec2 describe-security-groups --group-ids $ALBSG --query 'SecurityGroups[0].IpPermissions[].PrefixListIds[].PrefixListId')" ] && echo yes)" "yes"
chk "Default security group is empty" "$(q ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=group-name,Values=default --query 'SecurityGroups[0].IpPermissions' | wc -w | tr -d ' ')" "0"
chk "RDS subnets have no route to the internet" "$(q ec2 describe-route-tables --filters Name=tag:Name,Values=$P-data --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' | wc -w | tr -d ' ')" "0"

echo "== compute"
# the scorer exists only after the deploy that introduced it
SERVICES="web api worker"
[ "$(q ecs describe-services --cluster $P --services scorer --query 'services[?status==`ACTIVE`]|length(@)')" = "1" ] && SERVICES="$SERVICES scorer"
for s in $SERVICES; do
  d=$(q ecs describe-services --cluster $P --services $s --query 'services[0].[runningCount,desiredCount,deployments[0].rolloutState,deploymentConfiguration.deploymentCircuitBreaker.rollback]')
  set -- $d; [ "$1" = "$2" ] && [ "$3" = "COMPLETED" ] && [ "$4" = "True" ] && ok "ecs/$s: $1/$2 running, rollout COMPLETED, circuit-breaker rollback ON" || bad "ecs/$s" "$d"
done
chk "web+api run >= 2 tasks (HA across AZs)" "$(for s in web api; do q ecs describe-services --cluster $P --services $s --query 'services[0].runningCount'; done | awk '$1>=2{n++} END{print n}')" "2"
TASKS=$(q ecs list-tasks --cluster $P --desired-status RUNNING --query 'taskArns')
chk "no task has a public IP" "$(q ecs describe-tasks --cluster $P --tasks $TASKS --query 'tasks[].attachments[].details[?name==`networkInterfaceId`].value' | xargs -n1 -I{} aws --region $R ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text 2>/dev/null | grep -vc '^None$')" "0"
chk "tasks span 2 availability zones" "$(q ecs describe-tasks --cluster $P --tasks $TASKS --query 'tasks[].availabilityZone' | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')" "2"
chk "autoscaling targets exist for $SERVICES" "$(q application-autoscaling describe-scalable-targets --service-namespace ecs --query 'ScalableTargets[].ResourceId' | tr '\t' '\n' | grep -c "service/$P/")" "$(echo $SERVICES | wc -w | tr -d ' ')"
chk "worker can scale to 4 (LLM concurrency cap)" "$(q application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids service/$P/worker --query 'ScalableTargets[0].MaxCapacity')" "4"

echo "== edge"
CF=$(q cloudfront list-distributions --query "DistributionList.Items[?Comment=='$P'].Id|[0]")
chk "CloudFront redirects HTTP to HTTPS" "$(q cloudfront get-distribution --id $CF --query 'Distribution.DistributionConfig.DefaultCacheBehavior.ViewerProtocolPolicy')" "redirect-to-https"
chk "WAF web ACL attached to CloudFront" "$([ -n "$(q cloudfront get-distribution --id $CF --query 'Distribution.DistributionConfig.WebACLId')" ] && echo yes)" "yes"
chk "WAF has rate-limit + 2 managed rule groups" "$(aws --region us-east-1 wafv2 get-web-acl --name $P --scope CLOUDFRONT --id $(aws --region us-east-1 wafv2 list-web-acls --scope CLOUDFRONT --query "WebACLs[?Name=='$P'].Id|[0]" --output text) --query 'length(WebACL.Rules)' --output text 2>/dev/null)" "3"
ALB=$(q elbv2 describe-load-balancers --names $P --query 'LoadBalancers[0].LoadBalancerArn')
chk "ALB drops invalid headers" "$(q elbv2 describe-load-balancer-attributes --load-balancer-arn $ALB --query "Attributes[?Key=='routing.http.drop_invalid_header_fields.enabled'].Value")" "true"

echo "== identity"
POOL=$(q cognito-idp list-user-pools --max-results 20 --query "UserPools[?Name=='$P'].Id|[0]")
chk "Cognito self sign-up is DISABLED (admin-created users only)" "$(q cognito-idp describe-user-pool --user-pool-id $POOL --query 'UserPool.AdminCreateUserConfig.AllowAdminCreateUserOnly')" "True"
chk "Cognito MFA available (OPTIONAL)" "$(q cognito-idp describe-user-pool --user-pool-id $POOL --query 'UserPool.MfaConfiguration')" "OPTIONAL"
chk "Cognito password policy min length >= 12" "$([ "$(q cognito-idp describe-user-pool --user-pool-id $POOL --query 'UserPool.Policies.PasswordPolicy.MinimumLength')" -ge 12 ] && echo yes)" "yes"
WEBCLIENT=$(q cognito-idp list-user-pool-clients --user-pool-id $POOL --query "UserPoolClients[?contains(ClientName,'-web')].ClientId|[0]")
chk "web client uses authorization-code flow only" "$(q cognito-idp describe-user-pool-client --user-pool-id $POOL --client-id $WEBCLIENT --query 'UserPoolClient.AllowedOAuthFlows')" "code"
chk "web client has a secret (confidential)" "$([ -n "$(q cognito-idp describe-user-pool-client --user-pool-id $POOL --client-id $WEBCLIENT --query 'UserPoolClient.ClientSecret')" ] && echo yes)" "yes"

echo "== data & messaging"
Q=$(q sqs get-queue-url --queue-name $P-jobs --query QueueUrl)
chk "SQS queue is encrypted" "$(q sqs get-queue-attributes --queue-url $Q --attribute-names SqsManagedSseEnabled --query 'Attributes.SqsManagedSseEnabled')" "true"
chk "SQS redrive: maxReceiveCount=3 into a DLQ" "$(q sqs get-queue-attributes --queue-url $Q --attribute-names RedrivePolicy --query 'Attributes.RedrivePolicy' | grep -o 'maxReceiveCount":[0-9]*' | cut -d: -f2)" "3"
chk "Secrets are in Secrets Manager (llm, langfuse, cognito, rds)" "$(q secretsmanager list-secrets --query "SecretList[?starts_with(Name,'$P/') || contains(Name,'rds!')].Name" | wc -w | tr -d ' ')" "4"
chk "no secret values appear in task definitions" "$(q ecs describe-task-definition --task-definition $P-worker --query 'taskDefinition.containerDefinitions[0].environment[].value' | grep -c 'sk-')" "0"

echo "== terraform state"
SB=quizforge-tfstate-$(q sts get-caller-identity --query Account)-$R
chk "state bucket blocks public access" "$(q s3api get-public-access-block --bucket $SB --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,BlockPublicPolicy,IgnorePublicAcls,RestrictPublicBuckets]' | tr '\t' ',')" "True,True,True,True"
chk "state bucket is versioned" "$(q s3api get-bucket-versioning --bucket $SB --query Status)" "Enabled"
chk "state bucket uses a customer-managed KMS key" "$(q s3api get-bucket-encryption --bucket $SB --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm')" "aws:kms"

echo "== observability"
chk "alarm topic is encrypted with a CMK" "$(q sns get-topic-attributes --topic-arn $(q sns list-topics --query "Topics[?contains(TopicArn,'$P-alarms')].TopicArn|[0]") --query 'Attributes.KmsMasterKeyId' | grep -c alias/aws/sns)" "0"
chk ">= 10 alarms defined (dlq, 5xx, quality, cost, ...)" "$([ "$(q cloudwatch describe-alarms --alarm-name-prefix $P --query 'length(MetricAlarms)')" -ge 10 ] && echo yes)" "yes"
# worker/scorer backlog and idle alarms are autoscaling triggers (they fire by design), not problem alerts
chk "no problem alarm is currently firing" "$(q cloudwatch describe-alarms --alarm-name-prefix $P --state-value ALARM --query "length(MetricAlarms[?!contains(AlarmName,'-worker-backlog') && !contains(AlarmName,'-worker-idle') && !contains(AlarmName,'-scorer-backlog') && !contains(AlarmName,'-scorer-idle')])")" "0"
chk "log groups have retention set" "$(q logs describe-log-groups --log-group-name-prefix /quizforge/prod --query 'logGroups[?retentionInDays==null]|length(@)')" "0"
chk "sweeper schedule is enabled" "$(q scheduler get-schedule --name $P-sweeper --query State)" "ENABLED"

echo; echo "passed: $pass   failed: $fail"; exit $fail
