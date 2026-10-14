resource "aws_cognito_user_pool" "main" {
  name                     = local.name
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"
  deletion_protection      = var.deletion_protection ? "ACTIVE" : "INACTIVE"

  # Self sign-up (e-mail + password, e-mail verified) when allow_self_signup = true; otherwise an administrator
  # creates every user (scripts/create-user.sh).
  admin_create_user_config {
    allow_admin_create_user_only = !var.allow_self_signup
  }

  software_token_mfa_configuration { enabled = true }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project}-${var.environment}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# Social login. Created when the flag is on; the id and secret come from AWS Secrets Manager at deploy time (see docs/auth-setup.md).
# Federated users get a normal Cognito `sub`, so the API (access tokens only) is unchanged.
resource "aws_cognito_identity_provider" "google" {
  count         = var.google_enabled ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "openid email profile"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
  }

  # The real id and secret exist only in the deploy (read from Secrets Manager); plan and drift runs use placeholders.
  # They are set when the provider is created. To rotate them: terraform apply -replace on this resource.
  lifecycle { ignore_changes = [provider_details] }
}

resource "aws_cognito_identity_provider" "facebook" {
  count         = var.facebook_enabled ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Facebook"
  provider_type = "Facebook"

  provider_details = {
    client_id        = var.facebook_app_id
    client_secret    = var.facebook_app_secret
    authorize_scopes = "public_profile,email"
  }

  attribute_mapping = {
    email    = "email"
    username = "id"
  }

  lifecycle { ignore_changes = [provider_details] } # see the Google provider above
}

# Confidential client used by the Next.js server: Authorization Code + PKCE, secret never reaches the browser.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = local.web_identity_providers
  callback_urls                        = ["https://${aws_cloudfront_distribution.main.domain_name}/auth/callback"]
  logout_urls                          = ["https://${aws_cloudfront_distribution.main.domain_name}"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true

  depends_on = [aws_cognito_identity_provider.google, aws_cognito_identity_provider.facebook]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# Optional public client so REST consumers can get an access token with the AWS CLI (no secret to leak).
resource "aws_cognito_user_pool_client" "cli" {
  count                         = var.enable_cli_client ? 1 : 0
  name                          = "${local.name}-cli"
  user_pool_id                  = aws_cognito_user_pool.main.id
  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
  access_token_validity         = 60
  id_token_validity             = 60
  refresh_token_validity        = 7
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# Optional client for trying the REAL login (Cognito, Google, Facebook) from http://localhost:13000. Separate from the production client so
# the production client never accepts a localhost redirect. Off by default: turn it on only while testing (-var enable_local_dev_client=true).
resource "aws_cognito_user_pool_client" "local_dev" {
  count        = var.enable_local_dev_client ? 1 : 0
  name         = "${local.name}-local-dev"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = local.web_identity_providers
  callback_urls                        = ["http://localhost:13000/auth/callback"]
  logout_urls                          = ["http://localhost:13000"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true

  depends_on = [aws_cognito_identity_provider.google, aws_cognito_identity_provider.facebook]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 1
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

locals {
  social_providers       = concat(var.google_enabled ? ["google"] : [], var.facebook_enabled ? ["facebook"] : [])
  web_identity_providers = concat(["COGNITO"], aws_cognito_identity_provider.google[*].provider_name, aws_cognito_identity_provider.facebook[*].provider_name)
  cognito_client_ids     = concat([aws_cognito_user_pool_client.web.id], aws_cognito_user_pool_client.cli[*].id)
  cognito_domain_url     = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}
