#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
export TF_IN_AUTOMATION=1
export TF_INPUT=0
export PYTHONDONTWRITEBYTECODE=1
failed=0
infra_status=0

run() {
  printf '\n+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

summary() {
  if [ "$2" -eq 0 ]; then
    printf 'PASS %s\n' "$1"
  else
    printf 'FAIL %s\n' "$1"
    failed=1
  fi
}

infrastructure() {
  if ! compgen -G 'infra/*.tf' >/dev/null || ! compgen -G 'infra/bootstrap/*.tf' >/dev/null; then
    printf 'implementation missing: infra/*.tf and/or infra/bootstrap/*.tf\n'
    infra_status=1
    return
  fi
  run tofu -chdir=infra fmt -check -recursive || infra_status=1
  for directory in infra infra/bootstrap; do
    run tofu -chdir="$directory" init -backend=false -input=false -no-color || infra_status=1
    run tofu -chdir="$directory" validate -no-color || infra_status=1
  done
  run tofu -chdir=infra test -no-color || infra_status=1
}

infrastructure
summary A "$infra_status"

status=0
run npm --prefix worker test || status=1
summary B "$status"

status=0
run python3 -m unittest discover -s instance/tests || status=1
summary C "$status"

status=0
run python3 -m unittest discover -s tests/scripts || status=1
shopt -s nullglob
shell_files=(scripts/*.sh instance/*.sh)
if ! compgen -G 'scripts/*.sh' >/dev/null || ! compgen -G 'instance/*.sh' >/dev/null; then
  printf 'implementation missing: scripts/*.sh and/or instance/*.sh\n'
  status=1
else
  run shellcheck "${shell_files[@]}" || status=1
fi
summary D "$status"

status=0
run python3 -m unittest discover -s tests/workflow || status=1
workflow_files=(.github/workflows/*.yml)
if [ "${#workflow_files[@]}" -eq 0 ] || [ ! -f docs/caller-workflow.yml ]; then
  printf 'implementation missing: .github/workflows/*.yml and/or docs/caller-workflow.yml\n'
  status=1
else
  run actionlint "${workflow_files[@]}" docs/caller-workflow.yml || status=1
fi
summary E "$status"

summary F "$infra_status"
exit "$failed"
