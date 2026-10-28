# relay-terraform

Everything [Relay](https://github.com/LeonardoMatos07/relay) needs in AWS, as Terraform.

```
Relay -> SES -> SNS -> SQS relay-ses-events -> Lambda webhook-ses -> SQS relay-receipts -> Lambda relay-receipts -> Relay API
                          (raw SES events)      (raw -> neutral)                           (general webhook)
```

| File | What it creates |
|---|---|
| `main.tf` | SES identity, configuration set, event destination, SNS topic, `relay-ses-events` queue + DLQ |
| `dns.tf` | DKIM, SPF and DMARC records (Route 53 when `route53_zone_id` is set) |
| `iam.tf` | Send policy, optional IAM user/key, optional IRSA role for EKS |
| `receipts.tf` | `relay-receipts` queue + DLQ, DynamoDB ledger, the two Python Lambdas, IAM, event source mappings, DLQ alarms |

The Lambda code lives in [relay-receipts](https://github.com/LeonardoMatos07/relay-receipts); `receipts_source_dir` points at its `src` folder and Terraform zips it.

## Use

```bash
cp terraform.tfvars.example terraform.tfvars   # sender_email, test_recipients, ...
terraform init
terraform plan
terraform apply
```

Relay must be reachable from AWS before `relay-receipts` can call it. Until `relay_url` is set the function stays switched off and receipts wait in the queue (kept for `event_retention_seconds`). Once Relay has a public URL:

```bash
TF_VAR_relay_api_key=... terraform apply -var relay_url=https://relay.example.com
```

The key is stored as an SSM SecureString; the function reads it at run time.

## Decisions

- **SQS between the Lambdas, not API Gateway.** Buffering, retries and a DLQ come for free and nothing is exposed publicly. API Gateway is for providers that push to us (Twilio, ...); it would publish to the same `relay-receipts` queue.
- **State is local** and git-ignored (it holds the IAM key secret). Use the commented S3 backend in `versions.tf` for a team.
- Every DLQ has an alarm: anything that lands there needs a human.
