# Nightly red team on AWS

Every night a separate Fargate task attacks the real QuizForge pipeline with a fresh set of attacks, writes a report to S3, sends
metrics to CloudWatch and raises an alarm if the model obeyed a hidden instruction. It is not part of the always-on services.

## How it works

1. **EventBridge Scheduler** (`quizforge-prod-redteam`) runs an ECS `RunTask` at `cron(0 6 * * ? *)` (06:00 UTC, variable `redteam_schedule`).
2. The task `quizforge-prod-redteam` (Fargate, ARM64, 2 vCPU / 4 GB, private subnets, egress-only security group, no service, no load balancer) starts
   `scripts/redteam-nightly-aws.sh` from the image `quizforge/redteam` (`docker/redteam/Dockerfile`). The image has promptfoo at the pinned version and
   the Llama Prompt Guard 2 model baked in, like the worker image. The detector mode is the same as production (`injection_detector`).
3. The script runs `scripts/promptfoo.sh redteam-nightly`: 32 intents x `redteam_num_tests` fresh texts (default 10) x 2 cases (plain and jailbreak
   template) = about 640 tests. See `promptfoo/README.md` for the intents. Only plain code decides if an attack worked (a canary token in the reply).
4. Always, even when something leaked, it writes `summary.json`, `report.html` and `new-failures.json`, prints CloudWatch metrics (Embedded Metric Format)
   and uploads to S3. If a canary leaked it also publishes one message to the alarm topic. Then it exits with code 1 (a leak), 2 (upload failed) or 3 (no results).
5. Two alarms watch it: `quizforge-prod-redteam-leak` (any leak in a day) and `quizforge-prod-redteam-run-missing` (no run in 26 hours).

**Paused environment:** a paused environment has no NAT gateway, so the task could not reach the model API. The schedule is disabled and both alarms are
removed while `paused=true`. Switch the whole thing off with `redteam_enabled=false` (the bucket and old reports stay).

## S3 layout

Bucket `quizforge-prod-reports-<account id>`: private, encrypted with its own KMS key, versioning on, TLS only. Files go to Standard-IA after 30 days
and are deleted after 365 days.

```
redteam/2026-10-14T06-00-12Z/summary.json          one folder per run (UTC time of the start); never overwritten
redteam/2026-10-14T06-00-12Z/report.html
redteam/2026-10-14T06-00-12Z/new-failures.json     failing cases that are not already known, with the attack text
redteam/2026-10-14T06-00-12Z/redteam-nightly.json  the full promptfoo results
redteam/latest/summary.json                        a copy of the newest run (overwritten every night)
redteam/latest/report.html
```

## Open the latest report

```bash
AWS_PROFILE=<your profile> scripts/redteam-latest.sh          # prints a pre-signed link (7 days) and a one-line summary
AWS_PROFILE=<your profile> scripts/redteam-latest.sh 2026-10-14T06-00-12Z
AWS_PROFILE=<your profile> scripts/redteam-latest.sh --list
```

The link works as long as your own credentials work (an SSO session lasts some hours). The link in the alarm message is made by the task role and
stops working when the task credentials expire (a few hours), even though it asks for 7 days: use the script for a fresh one.

## Run it by hand

```bash
aws ecs run-task --cluster quizforge-prod --launch-type FARGATE --task-definition quizforge-prod-redteam \
  --network-configuration "awsvpcConfiguration={subnets=[<private subnet ids>],securityGroups=[<redteam security group id>],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"redteam","environment":[{"name":"REDTEAM_NUM_TESTS","value":"2"}]}]}'
```

A small `REDTEAM_NUM_TESTS` (1 to 3) is a cheap test of the whole chain. Logs: `/quizforge/prod/redteam`. Locally (no AWS, files in
`promptfoo/out/nightly/<run id>/`): `MINIMAX_API_KEY=... REDTEAM_NUM_TESTS=1 scripts/redteam-nightly-aws.sh` (promptfoo needs Node 22.22 or newer).

## How to read the report

* **KPI cards:** cases; rejected before the model (guard, language policy, detector, refused topic: cost nothing); rejected by the output rails (the model
  answered but the reply was refused); valid quiz (it passed the rails and the grounding check: the attack did not work); **LEAKED**; other failures
  (something unexpected, not a leak); model calls.
* **LEAKED** is the number that matters: the canary (a token like `ZX9-XRAY` that only an attack contains) was in the quiz, so the model obeyed the document.
  Each leaked case lists the canary, language, intent, strategy, an excerpt of the reply and the start of the attack.
* **Tables** by language, strategy, threat group and intent show where the leaks are. A leak in one language only means the guard or the prompt is weaker there.
* A high "valid quiz" count is not bad: the model read the attack and ignored it.

## Promote a leaked case to the frozen sample

1. Open `new-failures.json` of the run. Each entry has the attack text (`prompt`) and its `vars`.
2. Fix the cause (guard rules in `packages/core/src/injection-rules.ts`, the prompts, or the output rails in `packages/llm/src/output-guard.ts`).
3. Add the attack to the corpus so a pull request catches it from now on: either as a new test in `promptfoo/redteam/sample.yaml` (copy an entry, set
   `vars.prompt`, `vars.canary`, `metadata`) or, for a text attack, in `packages/core/src/attacks.ts`. Keep the sample size in sync with `promptfoo/README.md`.
4. Known cases that are not fixed yet can go to `promptfoo/redteam/known-failures.json` (`[{ "description": "...", "prompt": "..." }]`) so they are not reported as new.

## Cost

* Fargate ARM64, 2 vCPU / 4 GB: about 0.08 USD an hour. A run takes about an hour at 640 tests, so about **0.1 USD a night**.
* Model tokens (MiniMax-M2.7, 0.3 / 1.2 USD per million tokens in / out): measured about 640 input and 970 output tokens per generation, so about
  0.0014 USD per case that reaches the model. 640 cases plus the attacker model that writes the 320 texts: about **1 to 1.5 USD a night**.
  If the detector blocks more cases the bill is lower. The cost grows with `redteam_num_tests`.
* S3, logs, the KMS key: under 2 USD a month. Total at about 600 tests a night: roughly **35 to 50 USD a month**.
* While the environment is paused there is no run and no cost except the stored reports.

## Turn it on (first time)

1. Apply `infra/bootstrap` (creates the ECR repository `quizforge/redteam` and lets the deploy role manage the reports bucket). Do this BEFORE merging:
   the deploy job pushes the image to that repository and Terraform reads it.
2. Make sure the secret `quizforge-prod/llm` holds a real `MINIMAX_API_KEY` (`scripts/set-secrets.sh`): the task reads the same secret as the worker.
3. Merge and approve the deploy. It builds and pushes the `redteam` image with the other images, then applies `infra/terraform/redteam.tf`.
4. Confirm the alarm e-mail subscription (`ALARM_EMAIL`), then start one small run by hand (see above) and check `scripts/redteam-latest.sh`.
