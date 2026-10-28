# Least privilege for the Relay workers: SendEmail only, only from the configured sender, only
# through this configuration set. Nothing else in SES (no identity changes, no account reads).

locals {
  identity_arn = "arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/${local.identity}"
  config_arn   = "arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:configuration-set/${var.name}"
  recipient_arns = [
    for r in var.test_recipients : "arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/${r}"
  ]
}

data "aws_iam_policy_document" "send" {
  statement {
    sid       = "SendAsRelaySender"
    actions   = ["ses:SendEmail"]
    resources = concat([local.identity_arn, local.config_arn], local.recipient_arns)

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.sender_email]
    }
  }
}

resource "aws_iam_policy" "send" {
  name        = "${var.name}-ses-send"
  description = "Relay workers: send e-mail as ${var.sender_email} through the ${var.name} configuration set"
  policy      = data.aws_iam_policy_document.send.json
}

# --- Option 1: IAM user + access key (docker compose, local runs) ------------------------

resource "aws_iam_user" "sender" {
  count = var.create_access_key ? 1 : 0
  name  = "${var.name}-ses-sender"
}

resource "aws_iam_user_policy_attachment" "sender" {
  count      = var.create_access_key ? 1 : 0
  user       = aws_iam_user.sender[0].name
  policy_arn = aws_iam_policy.send.arn
}

resource "aws_iam_access_key" "sender" {
  count = var.create_access_key ? 1 : 0
  user  = aws_iam_user.sender[0].name
}

# --- Option 2: IAM role for the worker service account on EKS (no keys at all) ----------

data "aws_iam_policy_document" "irsa_trust" {
  count = var.eks_oidc_provider_arn != null ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.eks_oidc_provider_arn, "/^.*oidc-provider\\//", "")}:sub"
      values   = ["system:serviceaccount:${var.eks_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.eks_oidc_provider_arn, "/^.*oidc-provider\\//", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "worker" {
  count              = var.eks_oidc_provider_arn != null ? 1 : 0
  name               = "${var.name}-worker-ses"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[0].json
}

resource "aws_iam_role_policy_attachment" "worker" {
  count      = var.eks_oidc_provider_arn != null ? 1 : 0
  role       = aws_iam_role.worker[0].name
  policy_arn = aws_iam_policy.send.arn
}
