terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Remote state in S3 with native locking (no DynamoDB). Values are passed at init time (the bucket name carries the account id, so it is never committed):
  #   terraform init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="key=quizforge/prod/terraform.tfstate" \
  #     -backend-config="region=us-east-2" -backend-config="use_lockfile=true" -backend-config="encrypt=true"
  # (the bucket is created by ../bootstrap; scripts/_env.sh and the workflows do this for you)
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, Environment = var.environment, ManagedBy = "terraform" }
  }
}

# CloudFront WAF must live in us-east-1 regardless of the app region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = { Project = var.project, Environment = var.environment, ManagedBy = "terraform" }
  }
}
