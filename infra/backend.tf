terraform {
  backend "s3" {
    key                 = "sonarqube/terraform.tfstate"
    region              = "us-east-1"
    profile             = "sonarqube"
    allowed_account_ids = ["368861736633"]
    use_lockfile        = true
  }
}
