data "aws_caller_identity" "current" {}

locals {
  use_domain   = var.domain != null
  identity     = local.use_domain ? var.domain : var.sender_email
  mail_from    = local.use_domain ? "${var.mail_from_subdomain}.${var.domain}" : null
  dmarc_report = coalesce(var.dmarc_report_email, local.use_domain ? "dmarc@${var.domain}" : var.sender_email)
}

# --- Identity ---------------------------------------------------------------------------

# A domain identity gets Easy DKIM: SES generates the keys and signs every message; the domain
# publishes three CNAMEs (dns.tf). An e-mail identity is verified by clicking a link instead.
resource "aws_sesv2_email_identity" "sender" {
  email_identity         = local.identity
  configuration_set_name = aws_sesv2_configuration_set.this.configuration_set_name

  dynamic "dkim_signing_attributes" {
    for_each = local.use_domain ? [1] : []
    content {
      next_signing_key_length = "RSA_2048_BIT"
    }
  }
}

# Custom MAIL FROM: bounces go to mail.<domain> instead of amazonses.com, so SPF aligns with
# the From domain and DMARC can pass on SPF as well as DKIM.
resource "aws_sesv2_email_identity_mail_from_attributes" "sender" {
  count = local.use_domain ? 1 : 0

  email_identity         = aws_sesv2_email_identity.sender.email_identity
  mail_from_domain       = local.mail_from
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

# Sandbox only: recipients must be verified identities too.
resource "aws_sesv2_email_identity" "test_recipient" {
  for_each       = toset(var.test_recipients)
  email_identity = each.value
}

# --- Configuration set ------------------------------------------------------------------

# Relay names this set in every SendEmail (ses.configurationSet in the providers file).
resource "aws_sesv2_configuration_set" "this" {
  configuration_set_name = var.name

  delivery_options {
    tls_policy = "REQUIRE"
  }

  reputation_options {
    reputation_metrics_enabled = true
  }

  sending_options {
    sending_enabled = true
  }

  # Addresses that bounced or complained are not sent to again, which protects the account's
  # reputation (and its ability to send at all).
  suppression_options {
    suppressed_reasons = ["BOUNCE", "COMPLAINT"]
  }
}

# --- Delivery events: SES → SNS → SQS ---------------------------------------------------

# Each event carries the relay_message_id tag the adapter sets, so a consumer can update the
# final status of a message (delivered, bounced, complained). The queue buffers events until
# that consumer exists.
# Not encrypted with the AWS-managed alias/aws/sns key on purpose: its key policy cannot grant
# SES access, so SES would silently fail to publish. Use a customer-managed key that allows
# ses.amazonaws.com if topic encryption is required. The queue below is encrypted (SSE-SQS).
resource "aws_sns_topic" "events" {
  name = "${var.name}-ses-events"
}

resource "aws_sns_topic_policy" "events" {
  arn = aws_sns_topic.events.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSESPublish"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.events.arn
      Condition = {
        StringEquals = { "AWS:SourceAccount" = data.aws_caller_identity.current.account_id }
        StringLike   = { "AWS:SourceArn" = "arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:configuration-set/${var.name}" }
      }
    }]
  })
}

resource "aws_sesv2_configuration_set_event_destination" "sns" {
  configuration_set_name = aws_sesv2_configuration_set.this.configuration_set_name
  event_destination_name = "${var.name}-sns"

  event_destination {
    enabled = true
    matching_event_types = [
      "SEND",
      "DELIVERY",
      "BOUNCE",
      "COMPLAINT",
      "REJECT",
      "DELIVERY_DELAY",
      "RENDERING_FAILURE",
    ]

    sns_destination {
      topic_arn = aws_sns_topic.events.arn
    }
  }

  depends_on = [aws_sns_topic_policy.events]
}

resource "aws_sqs_queue" "events_dlq" {
  name                      = "${var.name}-ses-events-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "events" {
  name                       = "${var.name}-ses-events"
  message_retention_seconds  = var.event_retention_seconds
  visibility_timeout_seconds = local.visibility_timeout # six times the webhook-ses timeout
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSNS"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.events.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "events" {
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.events.arn
  raw_message_delivery = true
}
