# DNS records that make mail from the domain authenticate (DKIM, SPF, DMARC).
# Created in Route 53 when route53_zone_id is set; always listed in the dns_records output.

locals {
  # Easy DKIM always issues three tokens. count (not for_each) because the tokens are only
  # known after apply, and Terraform needs the number of records at plan time.
  dkim_count = local.use_domain ? 3 : 0

  dkim_tokens = local.use_domain ? try(tolist(aws_sesv2_email_identity.sender.dkim_signing_attributes[0].tokens), []) : []

  dns_records = local.use_domain ? concat(
    [for t in local.dkim_tokens : {
      name  = "${t}._domainkey.${var.domain}"
      type  = "CNAME"
      value = "${t}.dkim.amazonses.com"
    }],
    [
      {
        name  = local.mail_from
        type  = "MX"
        value = "10 feedback-smtp.${var.region}.amazonses.com"
      },
      {
        name  = local.mail_from
        type  = "TXT"
        value = "v=spf1 include:amazonses.com ~all"
      },
      {
        name  = "_dmarc.${var.domain}"
        type  = "TXT"
        value = "v=DMARC1; p=${var.dmarc_policy}; rua=mailto:${local.dmarc_report}"
      },
    ],
  ) : []

  manage_dns = local.use_domain && var.route53_zone_id != null
}

resource "aws_route53_record" "dkim" {
  count = local.manage_dns ? local.dkim_count : 0

  zone_id = var.route53_zone_id
  name    = "${local.dkim_tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${local.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "mail_from_mx" {
  count = local.manage_dns ? 1 : 0

  zone_id = var.route53_zone_id
  name    = local.mail_from
  type    = "MX"
  ttl     = 1800
  records = ["10 feedback-smtp.${var.region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  count = local.manage_dns ? 1 : 0

  zone_id = var.route53_zone_id
  name    = local.mail_from
  type    = "TXT"
  ttl     = 1800
  records = ["v=spf1 include:amazonses.com ~all"]
}

resource "aws_route53_record" "dmarc" {
  count = local.manage_dns ? 1 : 0

  zone_id = var.route53_zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 1800
  records = ["v=DMARC1; p=${var.dmarc_policy}; rua=mailto:${local.dmarc_report}"]
}
