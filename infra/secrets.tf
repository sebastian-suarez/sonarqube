resource "random_password" "db" {
  length           = 32
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "admin" {
  length           = 32
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "wake" {
  length  = 48
  special = false
}

resource "random_bytes" "jwt" {
  length = 32
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/sonarqube/db-password"
  type  = "SecureString"
  value = random_password.db.result
}

resource "aws_ssm_parameter" "admin_password" {
  name  = "/sonarqube/admin-password"
  type  = "SecureString"
  value = random_password.admin.result
}

resource "aws_ssm_parameter" "tunnel_token" {
  name  = "/sonarqube/tunnel-token"
  type  = "SecureString"
  value = data.cloudflare_zero_trust_tunnel_cloudflared_token.sonarqube.token
}

resource "aws_ssm_parameter" "wake_key" {
  name  = "/sonarqube/wake-key"
  type  = "SecureString"
  value = random_password.wake.result
}

resource "aws_ssm_parameter" "jwt_secret" {
  name  = "/sonarqube/jwt-secret"
  type  = "SecureString"
  value = random_bytes.jwt.base64
}
