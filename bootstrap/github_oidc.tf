############################ GitHub Actions -> AWS (no long-lived keys) ############################

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # GitHub's immutable subject: survives a repository rename or transfer, so a re-created repo with the same
  # name can never assume these roles. Format: repo:<owner>@<owner id>/<repo>@<repo id>:<context>
  sub_prefix = "repo:${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"
  oidc_arn   = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# PLAN role: read-only. PRs and branches of THIS repository may assume it. Fork PRs cannot: GitHub gives
# them no id-token, so no OIDC credentials are ever minted for untrusted code.
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.sub_prefix}:pull_request", "${local.sub_prefix}:ref:refs/heads/*"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.project}-gha-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "StateKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.state.arn]
  }
  statement {
    sid       = "StateReadAndLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"] # PutObject/DeleteObject only for the *.tflock lock file
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }
  statement {
    sid       = "StateRead"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# DEPLOY role: only the `main` branch, only through the `production` GitHub Environment (manual approval).
data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.sub_prefix}:environment:production"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.project}-gha-deploy"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "StateKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.state.arn]
  }
  statement {
    sid       = "TerraformState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "ECRRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
      "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:ListTagsForResource",
    ]
    resources = [for r in aws_ecr_repository.svc : r.arn]
  }
  # The stack manages these services. Names are prefixed `${project}-`, enforced for IAM below.
  statement {
    sid = "PlatformServices"
    actions = [
      "ec2:*", "elasticloadbalancing:*", "ecs:*", "rds:*", "sqs:*", "sns:*", "logs:*", "cloudwatch:*", "cloudfront:*",
      "wafv2:*", "cognito-idp:*", "secretsmanager:*", "servicediscovery:*", "application-autoscaling:*", "scheduler:*",
      "budgets:*", "events:*", "tag:*",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "KmsCreate"
    actions   = ["kms:CreateKey", "kms:ListAliases", "kms:ListKeys"]
    resources = ["*"]
  }
  statement {
    sid       = "KmsProjectKeys"
    actions   = ["kms:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project]
    }
  }
  statement {
    sid       = "KmsProjectAliases"
    actions   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
    resources = ["arn:${data.aws_partition.current.partition}:kms:${var.region}:${local.account_id}:alias/${var.project}-*"]
  }
  statement {
    sid     = "IAMProjectRoles"
    actions = ["iam:*"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/${var.project}-*",
      "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:policy/${var.project}-*",
      "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:instance-profile/${var.project}-*",
    ]
  }
  statement {
    sid       = "IAMReadAndServiceLinkedRoles"
    actions   = ["iam:Get*", "iam:List*", "iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy" {
  name   = "${var.project}-gha-deploy"
  policy = data.aws_iam_policy_document.deploy.json
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}
