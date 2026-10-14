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
   `<cognito-domain>` is the Cognito domain of the stack, for example `quizforge-prod-<account-id>.auth.eu-west-1.amazoncognito.com`. Get it with `terraform output` or in the Cognito console under App integration > Domain.
4. Copy the **Client ID** and **Client secret**.

## 2. Create the Facebook app

1. Open developers.facebook.com, **My Apps > Create app**, use case "Authenticate and request data from users with Facebook Login".
2. Add the product **Facebook Login > Settings**. In **Valid OAuth Redirect URIs** add exactly:
   `https://<cognito-domain>/oauth2/idpresponse`
3. Under **App settings > Basic** copy the **App ID** and **App secret**. Permissions needed: `public_profile` and `email`.
4. Switch the app to **Live** mode (in "Development" only the app roles can sign in).

## 3. The app callback

The web app code (login, callback, BFF) is in its own repository, [jhgcc1/quizforge-web](https://github.com/jhgcc1/quizforge-web); this repository pins the version it deploys in `web.ref`. The callback of the web app is already registered in Cognito by Terraform: `https://<cloudfront-domain>/auth/callback` (the `app_url` output plus `/auth/callback`). You do not add it to Google or Facebook. Those two only need the Cognito `idpresponse` URL above. If you add a custom domain later, add its `/auth/callback` to the Cognito web client.

## 4. GitHub secrets

In GitHub go to **Settings > Environments > production > Environment secrets** and create:

| Secret | Value |
| --- | --- |
| `GOOGLE_CLIENT_ID` | Google client ID |
| `GOOGLE_CLIENT_SECRET` | Google client secret |
| `FACEBOOK_APP_ID` | Facebook App ID |
| `FACEBOOK_APP_SECRET` | Facebook App secret |

Only the `deploy` job reads them (as `TF_VAR_*`). If a secret is missing, the value is empty and that provider is **not** created. You can enable only Google, only Facebook, both or none. Then run the pipeline on `main` (or re-run the deploy job). Terraform creates the identity providers, adds them to the web client, and sets `SOCIAL_PROVIDERS` (for example `google,facebook`) and `ALLOW_SIGNUP` on the web service, so the buttons appear.

The secrets are stored in the Terraform state (the state bucket is encrypted and private). Never put them in git.

For a local `terraform apply` use `TF_VAR_google_client_id=... ` style environment variables, not a tfvars file in git.

## 5. Turn sign-up off

Set `allow_self_signup = false` (for example `TF_VAR_allow_self_signup=false`, or in the deploy job env) and deploy. Cognito goes back to "administrator creates users" (`scripts/create-user.sh`) and the "Create account" button disappears. Existing accounts keep working. Social login is separate: with sign-up off, a first-time Google or Facebook login may still create a user in Cognito, so remove the provider secrets too if you want a closed system.

## 6. Risk: open sign-up

With sign-up on, **anyone on the internet can create an account**, and every account can start LLM generations that cost money. Controls that already exist:

* **E-mail verification**: an account needs a real e-mail that receives the code (Google and Facebook accounts come with a verified e-mail).
* **10 quizzes per day per user** in the API.
* **WAF rate limit** in front of CloudFront.
* **Daily LLM cost alarm** (CloudWatch alarm, e-mail to `alarm_email`).

These limit the damage but do not make it zero: someone can make many accounts. Watch the alarms. If abuse happens, set `allow_self_signup = false`, or disable a provider by removing its secrets.

## 7. Local development

With `AUTH_MODE=local` (docker compose) there is no Cognito. The buttons go to the dev login page, which says **SIMULATION**: no real Google or Facebook is used. Any user name works. This is for trying the flow and for the e2e test.

## What cannot be tested without real credentials

The Google and Facebook consent screens and the Cognito e-mail code need real accounts and a deployed stack. Unit tests cover the URL builder and the config; the e2e test covers the local simulation only.
