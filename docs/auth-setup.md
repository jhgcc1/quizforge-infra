# Sign-up and social login (Google, Facebook)

QuizForge uses Amazon Cognito (Hosted UI, Authorization Code + PKCE). Besides the normal e-mail login, people can:

* **Create an account** with e-mail + password. Cognito sends a code to the e-mail and the account only works after it is verified.
* **Continue with Google** or **Continue with Facebook**.

The "Create account" button shows when `allow_self_signup = true` (the default). Each social button shows only if that provider is set up. Nothing else changes: the API still accepts only Cognito **access tokens**. A Google or Facebook user gets a normal Cognito `sub`, so quizzes, the daily limit and everything else work the same.

## 1. Create the Google OAuth client

1. Open Google Cloud Console, create or pick a project, then **APIs & Services > OAuth consent screen**. Choose "External", fill the app name and e-mail, and publish the app (in "Testing" only listed test users can sign in).
2. **Credentials > Create credentials > OAuth client ID > Web application**.
3. Under **Authorized redirect URIs** add exactly:
   `https://<cognito-domain>/oauth2/idpresponse`
   `<cognito-domain>` is the Cognito domain of the stack, for example `quizforge-prod-<account-id>.auth.eu-west-1.amazoncognito.com`. Get it with `terraform output` (in `terraform/`) or in the Cognito console under App integration > Domain.
4. Copy the **Client ID** and **Client secret**.

## 2. Create the Facebook app

1. Open developers.facebook.com, **My Apps > Create app**, use case "Authenticate and request data from users with Facebook Login".
2. Add the product **Facebook Login > Settings**. In **Valid OAuth Redirect URIs** add exactly:
   `https://<cognito-domain>/oauth2/idpresponse`
3. Under **App settings > Basic** copy the **App ID** and **App secret**. Permissions needed: `public_profile` and `email`.
4. Switch the app to **Live** mode (in "Development" only the app roles can sign in).

## 3. The app callback

The web app code (login, callback, BFF) is in its own repository, [jhgcc1/quizforge-web](https://github.com/jhgcc1/quizforge-web); the version that is deployed is the `web_tag` input of the `deploy` workflow of this repository (default: what runs now). The callback of the web app is already registered in Cognito by Terraform: `https://<cloudfront-domain>/auth/callback` (the `app_url` output plus `/auth/callback`). You do not add it to Google or Facebook. Those two only need the Cognito `idpresponse` URL above. If you add a custom domain later, add its `/auth/callback` to the Cognito web client.

## 4. Where the secrets live: AWS Secrets Manager

The credentials are stored in AWS Secrets Manager, not in GitHub. Create two secrets (JSON with `client_id` and `client_secret`):

| Secret | Holds |
| --- | --- |
| `quizforge/prod/google-login` | Google client ID and secret |
| `quizforge/prod/facebook-login` | Facebook App ID and App secret |

```bash
aws secretsmanager create-secret --name quizforge/prod/google-login --secret-string '{"client_id":"...","client_secret":"..."}'
```

The `deploy` workflow reads them with the OIDC role (the `.github/actions/social-secrets` step masks the values and exports `TF_VAR_*`). The plan role cannot read them. Terraform creates the identity providers when `google_enabled` / `facebook_enabled` are `true` (in `prod.auto.tfvars`); with a flag off, that provider is not created. PR plans and the nightly drift run use placeholders, and `provider_details` is ignored after creation, so they show no change. To rotate a secret, update it in Secrets Manager and run `terraform apply -replace='aws_cognito_identity_provider.google[0]'` (or `facebook`). Terraform creates the identity providers, adds them to the web client, and sets `SOCIAL_PROVIDERS` and `ALLOW_SIGNUP` on the web service, so the buttons appear.

The values are also in the Terraform state (the state bucket is encrypted and private). Never put them in git.

## 5. Turn sign-up off

Set `allow_self_signup = false` (for example `TF_VAR_allow_self_signup=false`, or in `terraform/prod.auto.tfvars`) and deploy. Cognito goes back to "administrator creates users" (`scripts/create-user.sh`) and the "Create account" button disappears. Existing accounts keep working. Social login is separate: with sign-up off, a first-time Google or Facebook login may still create a user in Cognito, so remove the provider secrets too if you want a closed system.

## 6. Risk: open sign-up

With sign-up on, **anyone on the internet can create an account**, and every account can start LLM generations that cost money. Controls that already exist:

* **E-mail verification**: an account needs a real e-mail that receives the code (Google and Facebook accounts come with a verified e-mail).
* **10 quizzes per day per user** in the API.
* **WAF rate limit** in front of CloudFront.
* **Daily LLM cost alarm** (CloudWatch alarm, e-mail to `alarm_email`).

These limit the damage but do not make it zero: someone can make many accounts. Watch the alarms. If abuse happens, set `allow_self_signup = false`, or disable a provider by removing its secrets.

## 7. Local development (lives in the code repository)

The local stack (`docker-compose`, `scripts/local-cognito.sh`, the e2e test) is in the [quizforge](https://github.com/jhgcc1/quizforge) repository. What follows is kept here because the Terraform flag it needs is in this repository.

With `AUTH_MODE=local` (docker compose) there is no Cognito. The buttons go to the dev login page, which says **SIMULATION**: no real Google or Facebook is used. Any user name works. This is for trying the flow and for the e2e test.

## What cannot be tested without real credentials

The Google and Facebook consent screens and the Cognito e-mail code need real accounts and a deployed stack. Unit tests cover the URL builder and the config; the e2e test covers the local simulation only.

## Try the REAL login from your computer (localhost)

The local stack normally uses a development login (a simulation). To try the real sign-up and the Facebook / Google login from `http://localhost:13000`, run the local stack against the real Cognito user pool of the AWS account:

1. **Create the local client** (once, needs your approval, it changes AWS): apply Terraform (this repository, `deploy` workflow or a local apply) with `enable_local_dev_client=true`. It creates a separate Cognito app client, `quizforge-prod-local-dev`, whose only redirect is `http://localhost:13000/auth/callback`. The production client never accepts a localhost redirect. Switch it off again afterwards with `enable_local_dev_client=false`.
2. **Facebook / Google panels need nothing for localhost.** Their redirect stays the Cognito address plus `/oauth2/idpresponse`; only Cognito knows about localhost.
3. **Run it:** `AWS_PROFILE=... scripts/local-cognito.sh up` (in the code repository) fetches the client id and secret into `.env.cognito` (git-ignored, mode 600) and restarts the `api` and `web` containers in Cognito mode (`docker-compose.cognito.yml`). Open `http://localhost:13000`: **Create account**, e-mail login and **Continue with Facebook** now go through Cognito. The database, queue and worker stay local.
4. **Go back** to the simulation with `scripts/local-cognito.sh down`.

Notes: your Facebook app must be in development mode with you as an administrator or tester (or live), and the account you create is a real user in the production user pool.

