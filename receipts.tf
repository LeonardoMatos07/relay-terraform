# Delivery receipts: what providers say after Relay hands them a message.
#
#   SES --> SNS --> SQS (relay-ses-events) --> Lambda webhook-ses --> SQS (relay-receipts)
#                                                                          |
#                                                  Lambda relay-receipts --+--> Relay API
#
# The SES side (identity, configuration set, SNS topic, events queue) is in main.tf. The code of
# both functions lives in the relay-receipts repository.

locals {
  receipts_name  = "${var.name}-receipts"
  webhook_ses    = "${var.name}-webhook-ses"
  lambda_timeout = 15
  # AWS recommends a queue visibility timeout of at least six times the function timeout.
  visibility_timeout = local.lambda_timeout * 6
  consume_receipts   = var.relay_url != ""
}

# --- Queue between the two functions --------------------------------------------------------
# A queue, not an API Gateway: see docs/adr/0001 in the relay-receipts repository.

resource "aws_sqs_queue" "receipts_dlq" {
  name                      = "${local.receipts_name}-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "receipts" {
  name                       = local.receipts_name
  message_retention_seconds  = var.event_retention_seconds
  visibility_timeout_seconds = local.visibility_timeout
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.receipts_dlq.arn
    maxReceiveCount     = 5
  })
}

# --- Ledger: one item per receipt, so a receipt SQS delivers twice is handled once -----------

resource "aws_dynamodb_table" "ledger" {
  name         = "${local.receipts_name}-ledger"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }
}

# Relay's API key, read by the function at run time (never an environment variable).
resource "aws_ssm_parameter" "relay_api_key" {
  count = var.relay_api_key == "" ? 0 : 1

  name  = "/${var.name}/receipts/relay-api-key"
  type  = "SecureString"
  value = var.relay_api_key
}

# --- Code ------------------------------------------------------------------------------------

data "archive_file" "receipts" {
  type        = "zip"
  source_dir  = var.receipts_source_dir
  output_path = "${path.module}/.build/receipts.zip"
  excludes    = ["__pycache__", "relay_receipts/__pycache__", "relay_receipts/handlers/__pycache__"]
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- webhook-ses: raw SES events in, neutral receipts out ------------------------------------

resource "aws_cloudwatch_log_group" "webhook_ses" {
  name              = "/aws/lambda/${local.webhook_ses}"
  retention_in_days = var.lambda_log_retention_days
}

resource "aws_iam_role" "webhook_ses" {
  name               = local.webhook_ses
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "webhook_ses" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.webhook_ses.arn}:*"]
  }
  statement {
    sid       = "ReadSesEvents"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.events.arn]
  }
  statement {
    sid       = "WriteReceipts"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.receipts.arn]
  }
}

resource "aws_iam_role_policy" "webhook_ses" {
  name   = "access"
  role   = aws_iam_role.webhook_ses.id
  policy = data.aws_iam_policy_document.webhook_ses.json
}

resource "aws_lambda_function" "webhook_ses" {
  function_name    = local.webhook_ses
  description      = "Turns raw Amazon SES events into provider-neutral delivery receipts"
  role             = aws_iam_role.webhook_ses.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "relay_receipts.handlers.webhook_ses.handler"
  filename         = data.archive_file.receipts.output_path
  source_code_hash = data.archive_file.receipts.output_base64sha256
  timeout          = local.lambda_timeout
  memory_size      = 256

  environment {
    variables = {
      RECEIPTS_QUEUE_URL = aws_sqs_queue.receipts.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.webhook_ses, aws_iam_role_policy.webhook_ses]
}

resource "aws_lambda_event_source_mapping" "webhook_ses" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.webhook_ses.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 5
  }
}

# --- relay-receipts: the general webhook that hands receipts to Relay -------------------------

resource "aws_cloudwatch_log_group" "relay_receipts" {
  name              = "/aws/lambda/${local.receipts_name}"
  retention_in_days = var.lambda_log_retention_days
}

resource "aws_iam_role" "relay_receipts" {
  name               = local.receipts_name
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

data "aws_iam_policy_document" "relay_receipts" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.relay_receipts.arn}:*"]
  }
  statement {
    sid       = "ReadReceipts"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.receipts.arn]
  }
  statement {
    sid       = "Ledger"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.ledger.arn]
  }
  dynamic "statement" {
    for_each = aws_ssm_parameter.relay_api_key
    content {
      sid       = "RelayApiKey"
      actions   = ["ssm:GetParameter"]
      resources = [statement.value.arn]
    }
  }
  dynamic "statement" {
    for_each = aws_ssm_parameter.relay_api_key
    content {
      sid       = "DecryptRelayApiKey"
      actions   = ["kms:Decrypt"]
      resources = [data.aws_kms_alias.ssm.target_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "relay_receipts" {
  name   = "access"
  role   = aws_iam_role.relay_receipts.id
  policy = data.aws_iam_policy_document.relay_receipts.json
}

resource "aws_lambda_function" "relay_receipts" {
  function_name    = local.receipts_name
  description      = "General webhook: hands delivery receipts from any provider to Relay"
  role             = aws_iam_role.relay_receipts.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "relay_receipts.handlers.relay_receipts.handler"
  filename         = data.archive_file.receipts.output_path
  source_code_hash = data.archive_file.receipts.output_base64sha256
  timeout          = local.lambda_timeout
  memory_size      = 256

  environment {
    variables = merge(
      {
        RELAY_URL    = var.relay_url
        LEDGER_TABLE = aws_dynamodb_table.ledger.name
      },
      var.relay_api_key == "" ? {} : { RELAY_API_KEY_PARAM = aws_ssm_parameter.relay_api_key[0].name },
    )
  }

  depends_on = [aws_cloudwatch_log_group.relay_receipts, aws_iam_role_policy.relay_receipts]
}

# Off until Relay has a URL the function can reach: receipts wait safely in the queue (kept for
# var.event_retention_seconds) instead of failing against an address that does not exist.
resource "aws_lambda_event_source_mapping" "relay_receipts" {
  event_source_arn                   = aws_sqs_queue.receipts.arn
  function_name                      = aws_lambda_function.relay_receipts.arn
  enabled                            = local.consume_receipts
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]

  # Never open more than this many parallel calls against Relay.
  scaling_config {
    maximum_concurrency = 5
  }
}

# --- Alarms: anything in a dead-letter queue needs a human -----------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = {
    ses_events = aws_sqs_queue.events_dlq.name
    receipts   = aws_sqs_queue.receipts_dlq.name
  }

  alarm_name          = "${var.name}-dlq-${each.key}"
  alarm_description   = "Messages ended in ${each.value}: a receipt could not be processed after the retries"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}
