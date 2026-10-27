mock_provider "aws" {}

run "A14_bootstrap_private_versioned_encrypted_state" {
  command = plan
  module {
    source = "./bootstrap"
  }
  variables {
    bucket_name = "sonarqube-acceptance-state-123456789012"
  }
  assert {
    condition = (
      aws_s3_bucket.state.bucket == var.bucket_name &&
      can(regex("source\\s*=\\s*\"hashicorp/aws\"\\s+version\\s*=\\s*\"6\\.70\\.0\"", file("bootstrap/providers.tf"))) &&
      can(regex("(?s)provider\\s+\"aws\"\\s*\\{[^}]*profile\\s*=\\s*\"sonarqube\"[^}]*default_tags\\s*\\{", file("bootstrap/providers.tf"))) &&
      can(regex("(?s)provider\\s+\"aws\"\\s*\\{[^}]*allowed_account_ids\\s*=\\s*\\[\\s*\"368861736633\"\\s*\\][^}]*default_tags\\s*\\{", file("bootstrap/providers.tf"))) &&
      can(regex("(?s)default_tags\\s*\\{\\s*tags\\s*=\\s*\\{[^}]*Project\\s*=\\s*\"sonarqube\"", file("bootstrap/providers.tf")))
    )
    error_message = "A14/A15: bootstrap providers.tf must pin aws 6.70.0 and default Project tags, with profile sonarqube and allowed_account_ids [368861736633] before default_tags."
  }
  assert {
    condition = (
      aws_s3_bucket_versioning.state.bucket == aws_s3_bucket.state.id &&
      aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled" &&
      aws_s3_bucket_public_access_block.state.bucket == aws_s3_bucket.state.id &&
      aws_s3_bucket_public_access_block.state.block_public_acls &&
      aws_s3_bucket_public_access_block.state.block_public_policy &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls &&
      aws_s3_bucket_public_access_block.state.restrict_public_buckets &&
      aws_s3_bucket_server_side_encryption_configuration.state.bucket == aws_s3_bucket.state.id &&
      alltrue([for rule in aws_s3_bucket_server_side_encryption_configuration.state.rule : length(rule.apply_server_side_encryption_by_default) == 1 && alltrue([for encryption in rule.apply_server_side_encryption_by_default : contains(["AES256", "aws:kms"], encryption.sse_algorithm)])]) &&
      length(aws_s3_bucket_server_side_encryption_configuration.state.rule) > 0
    )
    error_message = "A14: bootstrap state bucket must be versioned, private and encrypted by default."
  }
}

