terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.70.0"
    }
  }
}

provider "aws" {
  region              = "us-east-1"
  profile             = "sonarqube"
  allowed_account_ids = ["368861736633"]

  default_tags {
    tags = {
      Project = "sonarqube"
    }
  }
}
