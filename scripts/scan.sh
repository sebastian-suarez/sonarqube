#!/usr/bin/env bash
set -euo pipefail

base=https://sonar.sebastiansuarez.dev
image=sonarsource/sonar-scanner-cli:12.3.0.4285_8.1.0

top=$(git rev-parse --show-toplevel)
if ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD); then
  default=${ref#origin/}
else
  default=$(git config --get init.defaultBranch || echo main)
fi
branch=$(git branch --show-current)
if [[ $branch != "$default" ]]; then
  echo "scan.sh: on branch '$branch'; scan only the default branch '$default'" >&2
  exit 1
fi
if [[ -n $(git status --porcelain --untracked-files=normal) ]]; then
  echo "scan.sh: uncommitted or untracked changes; scan a clean checkout" >&2
  exit 1
fi
if url=$(git remote get-url origin 2>/dev/null); then
  key=${url%/}; key=${key%.git}; key=${key##*[/:]}
else
  key=${top##*/}
fi

SONAR_TOKEN=$(security find-generic-password -s sonarqube-analysis-token -a "$USER" -w)
export SONAR_TOKEN
bash "$(dirname "$0")/wake.sh"

(
  pause=
  trap 'kill "$pause" 2>/dev/null; wait; exit' TERM
  while kill -0 "$$" 2>/dev/null; do
    printf 'header = "Authorization: Bearer %s"\n' "$SONAR_TOKEN" |
      curl -fsS -o /dev/null --max-time 30 -K - "$base/api/users/current" || true
    sleep "${SONAR_HEARTBEAT_SECONDS:-300}" & pause=$!
    wait "$pause"; pause=
  done
) &
heartbeat=$!
trap 'set +e; kill "$heartbeat" 2>/dev/null; wait "$heartbeat"' EXIT

docker run --rm -e SONAR_HOST_URL="$base" -e SONAR_TOKEN -v "$top:/usr/src:ro" "$image" -Dsonar.projectKey="$key"
