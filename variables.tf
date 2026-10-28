variable "region" {
  description = "AWS region for SES. Must match ses.region in the Relay providers file."
  type        = string
  default     = "sa-east-1"
}

variable "name" {
  description = "Prefix for every resource name (configuration set, IAM, SNS, SQS)."
  type        = string
  default     = "relay"
}

variable "sender_email" {
  description = "From address Relay sends as, e.g. no-reply@example.com."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.sender_email))
    error_message = "sender_email must be an e-mail address."
  }
}

variable "domain" {
  description = <<-EOT
    Domain to verify (recommended), e.g. example.com. Enables DKIM, a custom MAIL FROM, SPF
    and DMARC, and lets any address on the domain send. Leave null to verify only
    sender_email (SES e-mails a confirmation link to it).
  EOT
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Hosted zone of `domain`. When set, every DNS record is created automatically; otherwise they are listed in the dns_records output for you to create."
  type        = string
  default     = null
}

variable "mail_from_subdomain" {
  description = "Subdomain used as MAIL FROM (bounce domain), aligned with the sender for SPF."
  type        = string
  default     = "mail"
}

variable "dmarc_policy" {
  description = "DMARC policy. Start with none, watch the reports, then move to quarantine or reject."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "quarantine", "reject"], var.dmarc_policy)
    error_message = "dmarc_policy must be none, quarantine or reject."
  }
}

variable "dmarc_report_email" {
  description = "Where DMARC aggregate reports go. Defaults to dmarc@<domain>."
  type        = string
  default     = null
}

variable "test_recipients" {
  description = "Addresses to verify so the account can send to them while in the SES sandbox. Each receives a confirmation e-mail."
  type        = list(string)
  default     = []
}

variable "create_access_key" {
  description = "Create an access key for the sender IAM user (for docker compose). Its secret ends up in the Terraform state."
  type        = bool
  default     = true
}

variable "eks_oidc_provider_arn" {
  description = "Optional. OIDC provider ARN of an EKS cluster: creates an IAM role for the Relay worker service account (IRSA), so no access key is needed in Kubernetes."
  type        = string
  default     = null
}

variable "eks_service_account" {
  description = "namespace:name of the worker service account allowed to assume the IRSA role."
  type        = string
  default     = "relay:relay-worker"
}

variable "event_retention_seconds" {
  description = "How long SES events (deliveries, bounces, complaints) stay in the SQS queue."
  type        = number
  default     = 345600 # 4 days
}

variable "receipts_source_dir" {
  description = "Directory with the relay_receipts Python package (the src folder of the relay-receipts repository)."
  type        = string
  default     = "../relay-receipts/src"
}

variable "relay_url" {
  description = "Base URL of Relay's API as the Lambda sees it. Empty keeps relay-receipts switched off: receipts wait in the queue."
  type        = string
  default     = ""
}

variable "relay_api_key" {
  description = "Relay API key stored as an SSM SecureString for the relay-receipts function. Pass it with TF_VAR_relay_api_key, never in a file."
  type        = string
  default     = ""
  sensitive   = true
}

variable "lambda_log_retention_days" {
  type    = number
  default = 14
}
