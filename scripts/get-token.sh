#!/usr/bin/env bash
# Gets a Cognito ACCESS token for calling the REST API directly (uses the CLI app client).
# Usage: scripts/get-token.sh user@example.com 'password'   ->  prints the token
set -euo pipefail
cd "$(dirname "$0")/../infra/terraform"
aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH \
  --client-id "$(terraform output -raw cognito_cli_client_id)" \
  --auth-parameters "USERNAME=${1:?email},PASSWORD=${2:?password}" \
  --query 'AuthenticationResult.AccessToken' --output text
