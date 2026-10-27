#!/usr/bin/env bash
set -euo pipefail

repo=${1:?usage: onboard.sh owner/repo}
here=$(dirname "$0")

ssm() {
  aws ssm get-parameter --profile sonarqube --region us-east-1 --name "$1" --with-decryption --query Parameter.Value --output text
}
store() {
  printf 'add-generic-password -U -s %s -a %q -w %q\n' "$1" "$USER" "$2" | security -i
}

wake=$(ssm /sonarqube/wake-key)
store sonarqube-wake-key "$wake"
if ! token=$(security find-generic-password -s sonarqube-analysis-token -a "$USER" -w 2>/dev/null); then
  bash "$here/wake.sh"
  admin=$(ssm /sonarqube/admin-password)
  token=$(printf 'user = "admin:%s"\n' "$admin" |
    curl -fsS --max-time 30 -K - --data type=GLOBAL_ANALYSIS_TOKEN --data "name=analysis-$(date +%Y%m%d%H%M%S)" \
      https://sonar.sebastiansuarez.dev/api/user_tokens/generate |
    sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
  [[ -n $token ]] || { echo "onboard.sh: the token response had no token" >&2; exit 1; }
  store sonarqube-analysis-token "$token"
fi
printf '%s' "$token" | gh secret set SONAR_TOKEN -R "$repo"
printf '%s' "$wake" | gh secret set SONAR_WAKE_KEY -R "$repo"
echo "Commit this as .github/workflows/sonarqube.yml in $repo (change main if its default branch differs):"
cat "$here/../docs/caller-workflow.yml"
