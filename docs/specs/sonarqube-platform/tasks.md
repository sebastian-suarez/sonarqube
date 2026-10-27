# Tasks: sonarqube-platform

Ordered. Each task names its writer route and the check that proves it.

| # | Task | Route | Verification |
| --- | --- | --- | --- |
| 0 | Acceptance suite for groups A–F, derived from the spec | coding.overflow | the suite runs, and it fails where the code is missing |
| 1 | `git init`, `.gitignore` (`.terraform/`, `*.tfstate*`, `node_modules/`, `worker/dist/`, `graphify-out/`) and `.editorconfig` | hub | `git status` shows only intended files |
| 2 | Verify that the `sebastiansuarez.dev` zone exists and that a Cloudflare API token with the plan's scopes is available (user's go) | hub | the zone ID resolves through the Cloudflare API |
| 3 | `infra/bootstrap`: state bucket | coding.default | A1, A2, A14 |
| 4 | `infra/`: network, group, launch template, IAM, Aurora, SSM, budget, tunnel, DNS, Worker deploy, user data template | coding.default | A1–A15, F1–F3 |
| 5 | `worker/`: proxy, wake-credential checks (wake key, HS256 session), SigV4 call, build | coding.default | B1–B8 |
| 6 | `instance/`: idle checker and the boot helpers that user data installs (admin bootstrap gate) | coding.default | C1–C8, D1 |
| 7 | `scripts/` (`wake.sh`, `scan.sh` with the heartbeat, `onboard.sh`), the reusable workflow, the caller example and the README | coding.default | D1–D9, E1–E7 |
| 8 | Apply the bootstrap, then the main stack (user's go; this creates billable resources) | hub | `tofu plan` shows no changes after apply |
| 9 | Live checks | hub | G1–G4, G6 and G7, logged |
| 8a | Version 3: A16 test (coding.overflow), then the public-subnet Block Public Access exclusions in `infra/network.tf` and a README note (coding.default), then re-apply | coding.overflow, coding.default, hub | A1–A16 and the full suite; `tofu plan` empty after apply |
| 10 | Create the public GitHub repo `sebastian-suarez/sonarqube` and push (user's go), then onboard one repo | hub (project-setup skill) | G5, logged |
