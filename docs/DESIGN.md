# Design: three repositories, one pull deploy

## Why

Until now the application repository (`quizforge`) owned the code, the Terraform, the IAM bootstrap, the operations scripts and the deploy. A code
change could not be tested without a pipeline that could also change production, the deploy role had to trust the code repository, and the
infrastructure had no review path of its own. The infrastructure is now in its own repository and the deploy is a **pull**: this repository
decides what goes to production and when; the repositories that produce software only publish images.

## What each repository owns

| Repository | Owns | Does not own |
| --- | --- | --- |
| `jhgcc1/quizforge` (code) | `apps/api`, `apps/worker` (also the scorer, sweeper and migrate tasks: one image), `packages/*` (contract, core, db and its migrations, llm, detector), `evals`, `promptfoo`, `prompts`, the red team image (`docker/redteam`), `e2e`, `site/` reports, `web.ref`. CI: quality, integration, migrations, e2e, docker-build, secrets-scan, promptfoo, llm-eval(-pr), redteam-sample, publish-prompts. **Publishes** `quizforge/api`, `quizforge/worker`, `quizforge/redteam` to ECR | Terraform, IAM, the deploy, the AWS operations scripts |
| `jhgcc1/quizforge-web` (front end) | Next.js UI + BFF, its CI. **Publishes** `quizforge/web:web-<first 12 characters of the front end commit>` to ECR. Depends on the API contract by URL of a release tarball (`contract-vX.Y.Z`, built by the code repository's `release-contract.yml`) | everything else |
| `jhgcc1/quizforge-infra` (this) | `terraform/` (production stack), `bootstrap/` (state, ECR, OIDC roles), `github/` (rulesets, environments, variables), `scripts/` (operations), docs about AWS, auth, pause and the nightly red team, the `deploy`, `ci` and `drift` workflows | application code, image builds |

## How the three meet

```
 quizforge (code)            quizforge-web (front end)
   CI green on main            CI green on main
   publish job ----------+     publish job ---------+        OIDC role quizforge-gha-publish
   (arm64 build)         |     (arm64 build)        |        (ECR push only, main branches only)
                         v                          v
                  ECR  quizforge/api:<sha>     quizforge/web:web-<12>
                       quizforge/worker:<sha>
                       quizforge/redteam:<sha>          (immutable tags)
                                   |
                                   | pull: images by tag, checks of the code repo read through the public API
                                   v
 quizforge-infra  Actions > Deploy (manual)  --> resolve --> [approval: environment production] --> deploy
                                                 plan role (read only)                           deploy role
```

Contracts between the repositories (what must not change without changing the other side):

* **Image names and tags.** ECR repositories `quizforge/{web,api,worker,redteam}` are created by `bootstrap/`; tags are immutable. api, worker and
  redteam use the full commit sha of the code repository; web uses `web-<12 chars>` of the front end commit. The scorer, sweeper and migrate
  tasks run the worker image. All images are **linux/arm64** (Graviton Fargate, `cpu_architecture = ARM64`): the publish jobs must run on
  `ubuntu-24.04-arm` (or cross build); this repository builds nothing, so its runners are plain `ubuntu-24.04`.
* **Check names of the code repository** that gate a deploy: `quality`, `integration`, `migrations`, `e2e`, `docker-build`, `promptfoo`, `llm-eval`
  (`REQUIRED_CHECKS` in `deploy.yml`). The required checks of the code repository's own ruleset are managed here (`github/main.tf`) and use the
  same job names.
* **`web.ref` stays in the code repository.** It pins the front end commit the code is built and e2e-tested against (`docker-build`, `e2e`). It no
  longer decides what runs in production: the `web_tag` input does. To deploy exactly the tested front end, pass `web-$(cut -c1-12 web.ref)`.
* **The red team entrypoint** `scripts/redteam-nightly-aws.sh` is a path inside the redteam image (`terraform/redteam.tf` `command`). It stays in
  the code repository with the image.
* **Database migrations** are in the worker image (`packages/db`); the deploy runs them as the one-off `migrate` task of the *new* image before the
  new services start. Migrations must stay expand/contract.
* **Terraform state does not move.** Same bucket, same keys (`quizforge/prod|bootstrap|github/terraform.tfstate`). The bucket name carries the
  account id and is never committed: `TF_STATE_BUCKET` (repository variable) or `quizforge-tfstate-<account>-<region>`.

## The pull deploy (`.github/workflows/deploy.yml`)

Manual (`workflow_dispatch`), from `main` only. No token for another repository exists anywhere: the code repository is public, so its commits and
check runs are read with the workflow's own `GITHUB_TOKEN`; images are read with AWS credentials.

1. **resolve** (read-only `quizforge-gha-plan` role, runs before anyone approves anything). Refuses if `PAUSED=true`. Picks the tags: `image_tag`
   (default: newest of the last 30 commits of the code repository `main` with every required check successful and `api`, `worker`, `redteam` images in
   ECR), `web_tag` (default: what runs now, read from the ECS task definition). Verifies the images exist. Runs a plan with those tags and puts it in
   the job summary, so the approver sees the diff.
2. **deploy** (`environment: production`: the human approval; the `quizforge-gha-deploy` role trusts exactly this environment). Re-verifies the
   images, then: drift check (`plan -refresh-only`), migration one-off task **before** the new code (for scope `all`), a saved plan and `apply` of
   exactly that plan, and smoke tests through CloudFront (landing page, API spec, 401 without token and with a bad token, BFF and app pages need a
   session, the ALB is unreachable around CloudFront). `web-only` runs a targeted plan of the web task definition and service and fails if it
   destroys anything except an old task definition revision.

The social login credentials are read from Secrets Manager by the composite action `.github/actions/social-secrets` (masked, exported as
`TF_VAR_*`); plan jobs use placeholders (`provider_details` is ignored after creation).

`concurrency: deploy-production` serialises deploys; Terraform's S3 lock file serialises everything that touches the state.

## IAM and GitHub design

* `quizforge-gha-plan` (read only + state read + `*.tflock` write): trusted from pull requests and branches of the **infra** repository (until the
  cutover also of the code repository).
* `quizforge-gha-deploy`: trusted from `environment:production` of the **infra** repository (until the cutover also of the code repository). After
  the cutover it still carries ECR push rights that nothing needs any more; removing them is optional hardening.
* `quizforge-gha-publish` (new): ECR push to the four repositories only (auth token, layer upload, `PutImage`, `DescribeImages` and layer reads for
  reuse). Trusted from `refs/heads/main` of the code and front end repositories. It cannot touch state, ECS or IAM, and tags are immutable, so a
  compromised build can add an image but cannot replace one nor deploy it. One role serves two repositories (a single role cannot tell them apart in
  a resource policy); splitting it into a code role (api, worker, redteam) and a web role (web) is a cheap hardening if wanted.
* Subjects use GitHub's immutable form `repo:<owner>@<owner id>/<repo>@<repo id>:<context>`: a deleted and re-created repository with the same name
  cannot assume the roles. Ids: `gh api repos/jhgcc1/<repo> --jq .id`.
* `github/` manages this repository (ruleset `protect-main` with required checks `terraform-validate`, `trivy-config`, `secrets-scan`,
  `workflow-lint`, `terraform-plan`; environment `production` with the owner as required reviewer, `main` only; variables `AWS_REGION`,
  `AWS_PLAN_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, `ALARM_EMAIL`, `PAUSED`) and the code repository's ruleset and variables.

## Deviations from the first design brief

* `deploy.yml` has two jobs, with `resolve` before the approval, so that a refused or impossible deploy (paused, image missing, no green commit)
  never asks for an approval. Not in the original brief; costs nothing.
* The drift workflow now passes **both** tags (api and web). The old one passed only `image_tag`, which makes the web task definition show as drift
  as soon as the web tag differs from the api tag.
* The PR plan uses the tags that run now (read from ECS) instead of `pr-<n>`, so an unchanged repository plans "No changes" and a change shows only
  its own diff.
* `github/` also creates `AWS_PUBLISH_ROLE_ARN` in the code repository when `aws_publish_role_arn` is set. The front end repository is not managed
  by this stack: its variable is set by hand (`MIGRATION.md`).
* History: the paths were moved with `git filter-repo` (22 commits of history for the moved paths). `terraform/backend.hcl` (it held the account id
  and the bucket name) was dropped from every commit and an AWS profile name containing the account id (in a comment of `scripts/_env.sh`) was rewritten in its old commits.

## References to the code repository that were resolved

| Where | Reference | Resolution |
| --- | --- | --- |
| `scripts/_env.sh` | `REPO_ROOT/infra/terraform`; `backend.hcl`; `--repo jhgcc1/quizforge` (PAUSED, ALARM_EMAIL) | `REPO_ROOT/terraform`; init with `-backend-config` (bucket from `TF_STATE_BUCKET`, the repository variable, or the bootstrap naming convention); `INFRA_REPO` (default this repository), `PAUSED_REPOS` for the transition |
| `scripts/run-migration.sh`, `create-user.sh`, `get-token.sh` | `../infra/terraform` | `../terraform` |
| `scripts/set-secrets.sh` | `./.env` of the repository root | `ENV_FILE` (default `./.env`; point it at the code repository `.env`) |
| `terraform/*.tf` | none by path (no `file()`, `templatefile`, `../`); comments mentioning `infra/`, `scripts/`, `docker/` | comments updated; `redteam.tf` command `scripts/redteam-nightly-aws.sh` is a path inside the image (stays in the code repository) |
| `terraform/versions.tf`, `bootstrap/outputs.tf` | `backend.hcl` | backend settings passed at init time |
| `bootstrap/` | OIDC subjects of the code repository only | plan, deploy and publish subjects for three repositories (variables with the immutable ids) |
| `github/main.tf` | required check names of the code repository's `ci.yml`; `infra/bootstrap` comment | kept (a contract); `code_repo_terraform_checks` drops `terraform-validate` and `terraform-plan` at the cutover |
| old `ci.yml` jobs `deploy`, `terraform-plan`, `terraform-validate` | `web.ref`, `docker buildx build` of apps/ and docker/ and web/, `./.github/actions/social-secrets`, `infra/terraform`, `../../scripts/run-migration.sh` | no checkout of the code or front end, no image build (images come from ECR); paths `terraform/`, `../scripts/`; action copied |
| old `deploy-web.yml` | check-run gate on its own commit, `web.ref`, front end checkout and build | folded into `deploy.yml` (scope `web-only`, `web_tag`); the gate reads the code repository's checks |
| `docs/auth-setup.md`, `docs/redteam-nightly.md` | `web.ref`, `infra/bootstrap`, deploy job wording, local development | reworded for this repository; the local stack steps stay (they need a Terraform flag) but say they run in the code repository |
