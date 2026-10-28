terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }

  # Local state by default. The state holds the IAM access key secret when
  # create_access_key = true, so keep it out of git (see .gitignore) or move it to an
  # encrypted S3 backend:
  #
  # backend "s3" {
  #   bucket       = "your-tfstate-bucket"
  #   key          = "relay/ses.tfstate"
  #   region       = "sa-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "relay"
      ManagedBy = "terraform"
    }
  }
}
