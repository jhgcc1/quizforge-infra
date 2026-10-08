#!/usr/bin/env bash
# Creates a Cognito user (there is no public sign-up). Prints a one-time temporary password.
# Usage: scripts/create-user.sh someone@example.com
set -euo pipefail
email="${1:?usage: create-user.sh <email>}"
pool=$(cd "$(dirname "$0")/../infra/terraform" && terraform output -raw cognito_user_pool_id)
tmp="Qf-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 14)-9!"
aws cognito-idp admin-create-user --user-pool-id "$pool" --username "$email" --temporary-password "$tmp" \
  --message-action SUPPRESS --user-attributes Name=email,Value="$email" Name=email_verified,Value=true >/dev/null
echo "user:               $email"
echo "temporary password: $tmp   (must be changed at first sign-in)"
