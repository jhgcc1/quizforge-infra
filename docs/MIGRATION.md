# Migration: from the code repository to quizforge-infra

> **Historical record.** This describes the move as it was planned and carried out; it is not instructions. Some
> paths it names no longer exist in the code repository, which reorganised afterwards (`apps/` became `api/` and
> `worker/`, `promptfoo/` and the detector moved under `guardrails/`, the `site/` report generator was removed).
> Left as written, because a record of what was done is only useful if it is not edited later.

State of things when this was written (stage 1): this repository exists, seeded with the history of the moved paths; production is untouched; the
code repository still deploys. Everything below is **additive until the cutover** (step 6), and the Terraform state never moves.

Ids used by the code: owner `46584477`, `quizforge` repository `1409267817`, `quizforge-web` `1419364905`, `quizforge-infra` `1420996676`
(`gh api repos/jhgcc1/quizforge-infra --jq .id`; the immutable OIDC subject of the new repository was verified with
`gh api repos/jhgcc1/quizforge-infra/actions/oidc/customization/sub`).

## A. Coordinator checklist (changes outside stage 1's reach; the code is in this repository, nothing was applied)

All commands run from a checkout of the branch that contains these files (the PR of stage 1), with admin AWS credentials and a GitHub token that
can administer the repositories. Initialise each stack with the real backend (`$B` = the state bucket, `aws s3 ls | grep tfstate`):

```bash
init() { terraform init -input=false -reconfigure -backend-config="bucket=$B" -backend-config="key=quizforge/$1/terraform.tfstate" \
         -backend-config="region=us-east-2" -backend-config="use_lockfile=true" -backend-config="encrypt=true"; }
```

### A1. `bootstrap/` (IAM), additive

```bash
cd bootstrap && init bootstrap
terraform plan  -var create_oidc_provider=false
terraform apply -var create_oidc_provider=false
```

Plan result (run on stage 1, `-lock=false`): **2 to add, 2 to change, 0 to destroy**.

| Change | What |
| --- | --- |
| `aws_iam_role.deploy` in place | trust `sub` (StringEquals) becomes a list: **adds** `repo:jhgcc1@46584477/quizforge-infra@1420996676:environment:production`; keeps `repo:jhgcc1@46584477/quizforge@1409267817:environment:production` until the cutover |
| `aws_iam_role.plan` in place | trust `sub` (StringLike) **adds** `repo:jhgcc1@46584477/quizforge-infra@1420996676:pull_request` and `...:ref:refs/heads/*`; keeps the code repository's two |
| `aws_iam_role.publish` create | `quizforge-gha-publish`; trust: `refs/heads/main` of the code repository and of `quizforge-web` (StringEquals) |
| `aws_iam_role_policy.publish` create | inline `ecr-push`: `ecr:GetAuthorizationToken` on `*`; on the four ECR repositories only: `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `DescribeImages`, `BatchGetImage`, `GetDownloadUrlForLayer` |
| outputs | `+ gha_publish_role_arn` |

Nothing existing is removed or narrowed, so the current pipeline keeps working. After the apply: `terraform output gha_publish_role_arn`.

### A2. `github/`, additive

```bash
cd github && init github
export GITHUB_TOKEN=$(gh auth token)
v() { gh variable get "$1" --repo jhgcc1/quizforge; }
terraform plan -var reviewer_user_id=$(gh api user --jq .id) -var aws_plan_role_arn=$(v AWS_PLAN_ROLE_ARN) \
  -var aws_deploy_role_arn=$(v AWS_DEPLOY_ROLE_ARN) -var tf_state_bucket=$B -var alarm_email=$(v ALARM_EMAIL) \
  -var aws_publish_role_arn=<output of A1>
```

Plan result (run on stage 1, without `aws_publish_role_arn`): **1 to import, 10 to add, 1 to change, 0 to destroy**. With `aws_publish_role_arn` set:
one more add. The code repository's own resources show **no change**.

| Change | What |
| --- | --- |
| import `github_repository.infra` + update in place | `quizforge-infra`: merge commit and rebase merge off, squash with PR title/body, delete branch on merge (ignores `has_projects`/`has_wiki`) |
| `github_repository_vulnerability_alerts.infra` create | alerts on |
| `github_repository_ruleset.infra_main` create | `protect-main`: no deletion, no force push, linear history, PR with resolved threads, no bypass; required checks `terraform-validate`, `trivy-config`, `secrets-scan`, `workflow-lint`, `terraform-plan`, strict |
| `github_repository_environment.infra_production` + `..._deployment_policy.infra_main_only` create | environment `production`, required reviewer = `gh api user --jq .id` (46584477), `main` only |
| `github_actions_variable.infra_vars[...]` create (5) | `AWS_REGION`, `AWS_PLAN_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, `ALARM_EMAIL` in the infra repository |
| `github_actions_variable.infra_paused` create | `PAUSED` = `initial_paused` (default `false`: check the real state first, `scripts/env-status.sh`); after creation the pause and resume scripts own it |
| `github_actions_variable.code_publish_role[0]` create (only with `aws_publish_role_arn`) | `AWS_PUBLISH_ROLE_ARN` in the code repository |

Set by hand (not managed here): `gh variable set AWS_PUBLISH_ROLE_ARN --repo jhgcc1/quizforge-web --body <arn>` and
`gh variable set AWS_REGION --repo jhgcc1/quizforge-web --body us-east-2`.

The required checks of the code repository do **not** change here (`code_repo_terraform_checks` stays true until step 6).

### A3. Order and the chicken and egg

The checks of the stage 1 pull request (`terraform-plan` needs the plan role to trust this repository and the variables to exist) cannot go
green before A1 and A2. So: open the PR (done in stage 1), apply A1, apply A2 from the PR branch, re-run the PR checks, merge. The
ruleset only becomes active with A2, and the PR then satisfies it.

## B. Cutover plan (ordered, with checks and rollback)

Nothing changes in production in steps 1 to 4. Steps 5 to 7 are the cutover. Do it with no merges in flight to `jhgcc1/quizforge` `main`.

| # | Step | Check | Rollback |
| --- | --- | --- | --- |
| 0 | Record the baseline: `scripts/env-status.sh`; the running tags (`aws ecs describe-task-definition --task-definition quizforge-prod-api ...`); a local `terraform plan` of this repository says **No changes** | stage 1 report: No changes | n/a |
| 1 | A1 apply (IAM, additive) | `aws iam get-role --role-name quizforge-gha-plan --query Role.AssumeRolePolicyDocument` shows both repositories; the old pipeline still plans and deploys (open a throwaway PR in the code repository: `terraform-plan` is green) | re-apply the previous `bootstrap/` from the code repository (`infra/bootstrap`): removes the publish role and the new trust entries |
| 2 | A2 apply (GitHub, additive) | the PR checks of this repository go green; merge the PR; `deploy.yml` appears in Actions | `terraform destroy -target` of the new resources, or delete the environment and variables by hand; the code repository is unaffected |
| 3 | Stage 2, part 1: the code and front end repositories get a `publish` job (additive: the old `deploy` job still exists, and skips images already in ECR) | after merge, `aws ecr describe-images --repository-name quizforge/api --image-ids imageTag=<sha>` for api, worker, redteam; `quizforge/web` tag `web-<12>` | revert the PR; images are inert |
| 4 | First pull deploy, dry: run `deploy.yml` (`scope=web-only`, defaults). `resolve` must show requested tags equal to the running ones and a plan preview with **no changes**. Approve it only if you want to exercise the whole path (it is a no-op); otherwise cancel at the approval | `resolve` green, smoke tests green if approved | cancel the run; nothing was applied |
| 5 | **Cutover**: (a) apply `github/` with `-var code_repo_terraform_checks=false` (the code repository stops requiring `terraform-validate` and `terraform-plan`); (b) merge the code repository cutover PR (section C); it contains no deploy job, so nothing deploys | the merge is accepted; `main` CI of the code repository is green and its `publish` job pushed the new sha | `git revert` the cutover PR in the code repository (its old `deploy` returns; the deploy role still trusts it, because `keep_code_repo_trust` is still true); re-apply `github/` with `code_repo_terraform_checks=true` |
| 6 | First real pull deploy: `deploy.yml` with `scope=all`, defaults (newest green commit with images). Approve | `resolve` summary matches expectations; migration task OK; smoke tests OK; `scripts/env-status.sh` and `scripts/audit-aws.sh` pass; the next nightly `drift.yml` is green | the old version's tag is in ECR: run `deploy.yml` with `image_tag=<previous sha>` (expand/contract keeps the old code working with the migrated schema) |
| 7 | Remove the old trust: apply `bootstrap/` with `-var create_oidc_provider=false -var keep_code_repo_trust=false`; in `github/` delete the code repository's `github_repository_environment.production`, `github_repository_environment_deployment_policy.main_only`, `github_actions_variable.vars` (AWS_* variables; the code repository keeps `AWS_PUBLISH_ROLE_ARN`) and the `PAUSED`/`ALARM_EMAIL` variables set by scripts, then apply | `aws iam get-role ...` shows only the infra repository in plan and deploy trust; the code repository has no `production` environment | re-apply `bootstrap/` with `keep_code_repo_trust=true`, restore the environment and variables from git history |

State safety at every step: the state is versioned in S3 (`aws s3api list-object-versions --bucket $B --prefix quizforge/prod/terraform.tfstate`);
a bad state can be restored by copying an older version back. Locks are S3 lock files (`use_lockfile`); a stuck lock is removed with
`terraform force-unlock <id>` after checking no run is active. Until step 7, `PAUSED_REPOS="jhgcc1/quizforge-infra jhgcc1/quizforge"` keeps both
repositories' `PAUSED` variable in sync when you run `scripts/pause.sh` or `resume.sh`.

## C. Stage 2: the code repository cutover PR (description to use; not created in stage 1)

**Title:** Move the infrastructure and the deploy to quizforge-infra; publish images to ECR

Remove:

* `infra/` (`terraform`, `bootstrap`, `github`; now in `jhgcc1/quizforge-infra`), `gh.tfplan` and any local state files.
* Scripts that moved: `_env.sh`, `pause.sh`, `resume.sh`, `env-status.sh`, `audit-aws.sh`, `run-migration.sh`, `create-user.sh`, `get-token.sh`,
  `set-secrets.sh`, `redteam-latest.sh`. Keep `redteam-nightly-aws.sh` (image entrypoint), `local-cognito.sh`, `web.sh`, `smoke-api.mjs` and the rest.
* `.github/workflows/deploy-web.yml`, `.github/workflows/drift.yml`, `.github/actions/social-secrets`.
* From `ci.yml`: jobs `terraform-validate`, `terraform-plan` and `deploy`; the `terraform-validate` entry in the `needs` list that is removed with
  `deploy`; the `TF_VAR_*` environment variables. Keep `secrets-scan`, `docker-build`, `e2e` and everything else. Keep `web.ref` (e2e and
  docker-build still check the front end out at it).
* Fix `scripts/local-gates.sh` step 3 (Trivy scanned `/src/infra`: scan the code's own config or drop the step), `.dockerignore` and
  `eslint.config.mjs` entries for `infra`.

Add:

* A `publish` job in `ci.yml`, `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`, `needs: [quality, integration, migrations, e2e,
  docker-build, secrets-scan, promptfoo, llm-eval]`, `runs-on: ubuntu-24.04-arm` (the images are arm64), `permissions: { id-token: write, contents: read }`,
  no `environment`. Steps: `aws-actions/configure-aws-credentials@v4` with `role-to-assume: ${{ vars.AWS_PUBLISH_ROLE_ARN }}` and
  `aws-region: ${{ vars.AWS_REGION }}`, `aws-actions/amazon-ecr-login@v2`, `docker/setup-buildx-action@v3`, then for `api`, `worker` (`--target
  runtime-detector`) and `redteam` (`--build-arg GIT_SHA=$GITHUB_SHA`): skip if `aws ecr describe-images ... imageTag=$GITHUB_SHA` succeeds, else
  `docker buildx build -f <dockerfile> -t <registry>/quizforge/<s>:$GITHUB_SHA --push` with the gha cache scope `<s>-arm` (the exact loop of the old deploy job,
  minus `web`). Trivy-scan the pushed images in `docker-build` as today (the scan stays a PR gate).
* `AWS_PUBLISH_ROLE_ARN` and `AWS_REGION` repository variables (A2 sets the first; `AWS_REGION` already exists).

Update:

* `README.md` (the CI/CD paragraph, the `Deploy web` text, the infrastructure and operations sections, links to this repository), `docs/README.md`,
  and the architecture reports. `site/facts_repo.py` reads `infra/terraform/*.tf`, `infra/github/main.tf`, `scripts/audit-aws.sh` and the `deploy`
  job of `ci.yml`: give it an `INFRA_DIR` (a checkout of this repository, pinned like `web.ref` in an `infra.ref` file or passed by the report
  workflow) and update the paths (`terraform/`, `github/main.tf`, `scripts/audit-aws.sh` there); the deploy facts now come from this repository's
  `deploy.yml`. Regenerate `docs/architecture/*.html`.
* `docs/auth-setup.md` and `docs/redteam-nightly.md` now live in this repository: replace them by a link, keeping the local-development section of the
  first (it describes `local-cognito.sh`).

Front end repository (`quizforge-web`), a PR of its own: a `publish` job on `main` (after its CI): arm64 build of `web/Dockerfile`, push as
`quizforge/web:web-<first 12 characters of $GITHUB_SHA>` with the same role, skipping if the tag exists; variables `AWS_PUBLISH_ROLE_ARN` and `AWS_REGION`.

Required of the coordinator before merging the code repository PR: step 5(a) (the required checks), and no run of the old `deploy` in flight.

## D. Risks

* The deploy role keeps ECR push permissions after the cutover (harmless, one `terraform` edit to remove).
* One publish role for two repositories; a compromised front end `main` could push a tag to `quizforge/api` (immutable tags: it cannot replace an
  existing one, and nothing deploys it without an approval).
* `deploy.yml` and the PR plan have only been exercised locally in their Terraform part (a real plan against production: No changes) and with
  actionlint; the GitHub Actions run itself needs A1 and A2 first. The `resolve` job's commit scan relies on the check-run names of the code
  repository; renaming a job there stops auto-selection (pass `image_tag` explicitly).
* The default `web_tag` is what runs now, so a normal `scope=all` deploy does not move the web version. That is deliberate (the front end ships
  alone); say `web_tag=...` to move both.
* A paused environment: `resolve` fails fast with the instructions; `resume.sh` first.
