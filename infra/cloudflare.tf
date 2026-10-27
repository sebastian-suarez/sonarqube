resource "cloudflare_zero_trust_tunnel_cloudflared" "sonarqube" {
  account_id = var.cloudflare_account_id
  name       = "sonarqube"
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "sonarqube" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.sonarqube.id
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "sonarqube" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.sonarqube.id
  config = {
    ingress = [
      { hostname = "sonar.sebastiansuarez.dev", service = "http://localhost:9000" },
      { service = "http_status:404" },
    ]
  }
}

resource "cloudflare_dns_record" "sonar" {
  zone_id = var.cloudflare_zone_id
  name    = "sonar.sebastiansuarez.dev"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.sonarqube.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_workers_script" "sonarqube" {
  account_id         = var.cloudflare_account_id
  script_name        = "sonarqube"
  content            = file("${path.module}/../worker/src/index.js")
  main_module        = "index.js"
  compatibility_date = "2026-10-01"
  bindings = [
    { name = "AWS_ACCESS_KEY_ID", type = "secret_text", text = aws_iam_access_key.worker.id },
    { name = "AWS_SECRET_ACCESS_KEY", type = "secret_text", text = aws_iam_access_key.worker.secret },
    { name = "WAKE_KEY", type = "secret_text", text = random_password.wake.result },
    { name = "JWT_SECRET", type = "secret_text", text = random_bytes.jwt.base64 },
    { name = "ASG_NAME", type = "plain_text", text = aws_autoscaling_group.sonarqube.name },
    { name = "AWS_REGION", type = "plain_text", text = "us-east-1" },
  ]
}

resource "cloudflare_workers_route" "sonar" {
  zone_id = var.cloudflare_zone_id
  pattern = "sonar.sebastiansuarez.dev/*"
  script  = cloudflare_workers_script.sonarqube.script_name
}
