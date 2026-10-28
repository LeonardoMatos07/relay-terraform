output "identity" {
  description = "Verified identity (domain or address) and its type."
  value = {
    name = aws_sesv2_email_identity.sender.email_identity
    type = aws_sesv2_email_identity.sender.identity_type
  }
}

output "dns_records" {
  description = "Records to publish for DKIM, SPF and DMARC. Already created when route53_zone_id is set."
  value       = local.dns_records
}

output "configuration_set" {
  value = aws_sesv2_configuration_set.this.configuration_set_name
}

output "events_queue_url" {
  description = "SQS queue receiving SES delivery, bounce and complaint events."
  value       = aws_sqs_queue.events.id
}

output "relay_provider" {
  description = "Entry to paste into config/providers.real.json."
  value = jsonencode({
    name          = "ses"
    type          = "ses"
    channel       = "email"
    priority      = 1
    ratePerSecond = 1
    burst         = 1
    ses = {
      region           = var.region
      from             = var.sender_email
      configurationSet = aws_sesv2_configuration_set.this.configuration_set_name
    }
  })
}

output "access_key_id" {
  description = "AWS_ACCESS_KEY_ID for .env (when create_access_key = true)."
  value       = var.create_access_key ? aws_iam_access_key.sender[0].id : null
}

output "secret_access_key" {
  description = "AWS_SECRET_ACCESS_KEY for .env. Read with: terraform output -raw secret_access_key"
  value       = var.create_access_key ? aws_iam_access_key.sender[0].secret : null
  sensitive   = true
}

output "worker_role_arn" {
  description = "IAM role for the worker service account (annotate it with eks.amazonaws.com/role-arn)."
  value       = var.eks_oidc_provider_arn != null ? aws_iam_role.worker[0].arn : null
}

output "receipts_queue_url" {
  description = "Queue where webhook-ses (and any future provider webhook) publishes neutral receipts."
  value       = aws_sqs_queue.receipts.id
}

output "receipts_dlq_url" {
  value = aws_sqs_queue.receipts_dlq.id
}

output "ledger_table" {
  value = aws_dynamodb_table.ledger.name
}

output "lambdas" {
  value = {
    webhook_ses    = aws_lambda_function.webhook_ses.function_name
    relay_receipts = aws_lambda_function.relay_receipts.function_name
  }
}
