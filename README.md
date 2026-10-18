# quizforge-infra

Infrastructure (Terraform on AWS), deploy and operations for [QuizForge](https://github.com/jhgcc1/quizforge). This repository owns everything that
exists in the AWS account and everything that changes it. The application code lives in
[jhgcc1/quizforge](https://github.com/jhgcc1/quizforge), the front end in [jhgcc1/quizforge-web](https://github.com/jhgcc1/quizforge-web); they only
publish container images to ECR. See [docs/DESIGN.md](docs/DESIGN.md) for how the three repositories fit together.

## Layout

| Path | What |
| --- | --- |
| `terraform/` | the production stack (VPC, RDS, ECS Fargate, ALB, CloudFront + WAF, Cognito, SQS, observability, nightly red team). State: S3, key `quizforge/prod/terraform.tfstate` |
| `bootstrap/` | state bucket and KMS key, ECR repositories, the GitHub OIDC roles (`quizforge-gha-plan`, `-deploy`, `-publish`). State key `quizforge/bootstrap/terraform.tfstate` |
| `github/` | GitHub settings of this repository and of the code repository: rulesets, the `production` environment, variables. State key `quizforge/github/terraform.tfstate` |
| `scripts/` | operations of the deployed environment: `pause.sh`, `resume.sh`, `env-status.sh`, `audit-aws.sh`, `run-migration.sh`, `create-user.sh`, `get-token.sh`, `set-secrets.sh`, `redteam-latest.sh` |
| `docs/` | `DESIGN.md`, `MIGRATION.md`, `auth-setup.md` (sign-up, Google and Facebook), `redteam-nightly.md` |
| `.github/workflows/` | `ci.yml` (every PR), `deploy.yml` (manual, production), `drift.yml` (nightly) |

Nothing here contains the AWS account id or the state bucket name: they come from repository variables (`TF_STATE_BUCKET`, ...) or from your
AWS credentials at run time.

## Deploy

Actions > **Deploy** > Run workflow (branch `main`). There is nothing to type: a deploy always takes the **main of each side**.

| Input | Meaning |
| --- | --- |
| `scope` | `all` (back end and front end), `api` (back end only: api, worker, scorer, redteam, migrate), `web` (front end only) |

1. `resolve` (no approval needed, read-only role): refuses if the environment is paused, then resolves each side to the newest commit of its
   `main` whose required checks are green **and** whose images are already in ECR — `quality integration migrations docker-build promptfoo
   llm-eval` for [`jhgcc1/quizforge`](https://github.com/jhgcc1/quizforge), `quality build e2e docker-build secrets-scan` for
   [`jhgcc1/quizforge-web`](https://github.com/jhgcc1/quizforge-web). It writes what changes and a plan preview to the job summary.
2. `apply` (the reusable `apply.yml`) waits for the approval of the `production` environment, then: drift check, **database migration before the
   new code**, plan, apply, smoke tests through CloudFront. A `web` deploy runs a targeted plan and refuses anything that destroys something other
   than an old web task definition revision.

## Rollback

Actions > **Rollback** > Run workflow. This is the only place where a tag is typed by hand, so a stale tag can never reach production through a
distracted click on the normal path.

| Input | Meaning |
| --- | --- |
| `image_tag` | the api/worker tag to go back to. Empty = leave the back end as it is |
| `web_tag` | the web tag to go back to, for example `web-0123456789ab`. Empty = leave the front end as it is |

At least one is required, and at least one must differ from what is running. It goes through the same `apply.yml` as a deploy: same approval, same
drift check, same smoke tests. **The database migration is not undone** — schema changes are expand/contract, so the older code keeps working
against the newer schema.

Where to find a tag: the summary of any past Deploy run, or

```bash
aws ecs describe-task-definition --task-definition quizforge-prod-api --query 'taskDefinition.containerDefinitions[0].image'
```

**Who can approve:** the reviewers of the `production` environment (the repository owner, `jhgcc1`; configured in `github/infra_repo.tf`). The
environment only accepts runs from `main`, and the deploy IAM role trusts only this environment of this repository.

## Pause and resume

```bash
AWS_PROFILE=<profile> scripts/pause.sh     # stops most of the bill, keeps all data (about US$0.3/day)
AWS_PROFILE=<profile> scripts/resume.sh    # about 10 minutes
AWS_PROFILE=<profile> scripts/env-status.sh
```

Both scripts keep the running versions (read from ECS), read the social login credentials from Secrets Manager, and set the repository variable
`PAUSED`, which makes `deploy.yml` refuse to run while paused. They need `aws`, `terraform` >= 1.10, `jq` and (optionally) `gh`.

## Other operations

```bash
scripts/audit-aws.sh                       # read-only audit of the deployed environment against the security claims
scripts/create-user.sh someone@example.com # Cognito user (temporary password is printed once)
scripts/get-token.sh user@example.com 'pw' # access token to call the API directly
ENV_FILE=../quizforge/.env scripts/set-secrets.sh   # LLM and Langfuse keys straight into Secrets Manager (never in state or git)
scripts/redteam-latest.sh                  # link to the newest nightly red team report
```

## Local Terraform

```bash
cd terraform
terraform init -backend-config="bucket=$(gh variable get TF_STATE_BUCKET --repo jhgcc1/quizforge-infra)" \
  -backend-config="key=quizforge/prod/terraform.tfstate" -backend-config="region=us-east-2" \
  -backend-config="use_lockfile=true" -backend-config="encrypt=true"
# a plan that must say "No changes" on an unchanged repository: the tags that run now, the social secrets from Secrets Manager
```

`scripts/_env.sh` does the init and the secret loading for the pause and resume scripts. Do not `terraform apply` from a laptop unless the
pipeline cannot do it (pause, resume, bootstrap and the `github/` stack are the intended exceptions).

## CI

Every pull request: `terraform-validate` (fmt, validate of the three stacks, script syntax), `trivy-config`, `secrets-scan` (gitleaks on the
full history, no account id or state bucket name in any file), `workflow-lint` (actionlint), and `terraform-plan` (read-only plan of production,
commented on the PR). `drift.yml` runs a plan every night and opens one issue when reality differs from the state.
