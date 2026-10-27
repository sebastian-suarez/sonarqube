#!/usr/bin/env bash
set -euo pipefail

wait_seconds=${SONAR_WAIT_SECONDS:-900}
key=$(security find-generic-password -s sonarqube-wake-key -a "$USER" -w)
up='"status"[[:space:]]*:[[:space:]]*"UP"'
deadline=$((SECONDS + wait_seconds))
echo "Waking https://sonar.sebastiansuarez.dev (up to ${wait_seconds}s)" >&2
until body=$(printf 'header = "X-Sonar-Wake-Key: %s"\n' "$key" |
  curl -sS --max-time 10 -K - https://sonar.sebastiansuarez.dev/api/system/status) && [[ $body =~ $up ]]; do
  if ((SECONDS >= deadline)); then
    echo "wake.sh: SonarQube is not UP after ${wait_seconds}s" >&2
    exit 1
  fi
  sleep "${SONAR_POLL_SECONDS:-5}"
done
