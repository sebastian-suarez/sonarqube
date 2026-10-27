#!/bin/bash
set -euo pipefail
: "${DB_HOST:?}"
: "${SONAR_JDBC_URL:?}"
: "${SONAR_JDBC_USERNAME:?}"
: "${SONARQUBE_IMAGE:?}"
: "${IDLE_CHECK_B64:?}"

# The idle timer goes first, so a failure in any later step still scales the instance in.
base64 -d <<<"$IDLE_CHECK_B64" >/usr/local/bin/idle_check.py
cat >/etc/systemd/system/sonarqube-idle.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/idle_check.py
EOF
cat >/etc/systemd/system/sonarqube-idle.timer <<'EOF'
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl enable --now sonarqube-idle.timer

printf '%s\n' vm.max_map_count=524288 fs.file-max=131072 >/etc/sysctl.d/99-sonarqube.conf
sysctl --system >/dev/null

dnf install -y docker https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm

cat >/etc/systemd/system/sonarqube.service <<EOF
[Unit]
Requires=docker.service
After=docker.service

[Service]
ExecStart=docker run --rm --name sonarqube --stop-timeout 120 --ulimit nofile=131072:131072 -p 127.0.0.1:9000:9000 -v /run/sonarqube/sonar.properties:/opt/sonarqube/conf/sonar.properties:ro -v /var/log/sonarqube/access.log:/opt/sonarqube/logs/access.log $SONARQUBE_IMAGE
ExecStop=docker stop sonarqube
TimeoutStopSec=150
Restart=on-failure
RestartSec=10
EOF
cat >/etc/systemd/system/cloudflared.service <<'EOF'
[Service]
EnvironmentFile=/run/sonarqube/cloudflared.env
ExecStart=cloudflared tunnel run --token ${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=10
EOF
systemctl daemon-reload
install -D -o 1000 -m 644 /dev/null /var/log/sonarqube/access.log

param() { aws ssm get-parameter --region us-east-1 --with-decryption --query Parameter.Value --output text --name "$1"; }
DB_PASSWORD=$(param /sonarqube/db-password)
ADMIN_PASSWORD=$(param /sonarqube/admin-password)
TUNNEL_TOKEN=$(param /sonarqube/tunnel-token)
JWT_SECRET=$(param /sonarqube/jwt-secret)

umask 077
mkdir -p /run/sonarqube
printf '%s' "$ADMIN_PASSWORD" >/run/sonarqube/admin-password
printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" >/run/sonarqube/cloudflared.env
cat >/run/sonarqube/sonar.properties <<EOF
sonar.jdbc.url=$SONAR_JDBC_URL
sonar.jdbc.username=$SONAR_JDBC_USERNAME
sonar.jdbc.password=$DB_PASSWORD
sonar.auth.jwtBase64Hs256Secret=$JWT_SECRET
sonar.web.accessLogs.pattern=%h %l %reqAttribute{LOGIN} [%t{dd/MMM/yyyy:HH:mm:ss Z}] "%r" %s %b "%i{User-Agent}"
EOF
chown 1000 /run/sonarqube/sonar.properties

timeout 180 bash -c "until : 2>/dev/null >/dev/tcp/$DB_HOST/5432; do sleep 2; done" || { echo "$DB_HOST:5432 is not accepting connections" >&2; exit 1; }
systemctl start sonarqube

admin_authenticates() {
  [[ $(curl -fs -K - http://localhost:9000/api/authentication/validate <<<"user = admin:$1") == *'"valid":true'* ]]
}

change_admin_password() {
  curl -fsS -K - http://localhost:9000/api/users/change_password <<EOF
user = admin:admin
data = login=admin&previousPassword=admin
data-urlencode = password=$ADMIN_PASSWORD
EOF
}

until [[ $(curl -fs http://localhost:9000/api/system/status) == *'"status":"UP"'* ]]; do sleep 5; done
if admin_authenticates admin; then
  change_admin_password || { echo "admin password change failed" >&2; exit 1; }
fi
if admin_authenticates "$ADMIN_PASSWORD" && ! admin_authenticates admin; then
  systemctl start cloudflared
else
  echo "admin bootstrap verification failed; cloudflared remains stopped" >&2
fi
