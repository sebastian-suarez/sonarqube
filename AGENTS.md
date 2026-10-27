# AGENTS.md

Guidance for coding agents working in this repository.

## Purpose

A single-user, low-cost SonarQube Community Build on AWS Spot capacity behind Cloudflare. GitHub Actions in the user's other repos and local scans of `~/Projects` repos use it. It scales to zero when idle and wakes when it gets called.

## Status

Spec version 4 (2026-10-27). The stack is being redeployed into the dedicated `sonarqube` account after a first deploy to the management account, which has been torn down. The live checks (group G) are still pending. The design, acceptance criteria, task order and log live in `docs/specs/sonarqube-platform/`. That spec is the source of truth; this file only summarizes it. Deploy steps, onboarding, upgrades and teardown are in `README.md`.

## Commands

```sh
bash tests/run-acceptance.sh                                     # every offline group A–F; one PASS/FAIL line each
tofu -chdir=infra test                                           # A and F (mock providers, no credentials)
tofu -chdir=infra test -filter=tests/bootstrap.tftest.hcl        # one test file
npm --prefix worker test                                         # B
(cd worker && node --test --test-name-pattern='^B5' test/*.test.js)  # one Worker criterion
python3 -m unittest discover -s instance/tests -k C7             # C, one test by name
python3 -m unittest discover -s tests/scripts                    # D
python3 -m unittest discover -s tests/workflow                   # E (YAML is parsed by the system ruby)
shellcheck scripts/*.sh instance/*.sh
actionlint .github/workflows/*.yml docs/caller-workflow.yml
```

In a sandbox without network, set `TF_CLI_CONFIG_FILE=~/.cache/routing/sonarqube/tofu-mirror/tofurc`, an offline mirror of the three pinned providers, before running any `tofu` command.

## Protected tests

`infra/tests/`, `worker/test/`, `instance/tests/` and `tests/` are hashed in `docs/specs/sonarqube-platform/ready.json`, and `spec.sh check sonarqube-platform` (the owner's spec harness) verifies them. Don't edit them without `spec.sh invalidate` and the user's go. `tests/CONTRACT.md` is the binding interface: resource addresses, environment knobs, the exact access-log pattern and the admin-gate block.

## Architecture

Request path: caller → Cloudflare Worker on `sonar.sebastiansuarez.dev` → Cloudflare Tunnel → cloudflared and the SonarQube container on a Spot instance → Aurora.

- **Callers.** A reusable GitHub Actions workflow published from this public repo, and `scripts/wake.sh` and `scripts/scan.sh` for local use. They share one global analysis token and one wake key. Both live in the macOS Keychain locally and are set as each repo's `SONAR_TOKEN` and `SONAR_WAKE_KEY` by `scripts/onboard.sh`. Callers send `X-Sonar-Wake-Key` while polling `/api/system/status` until `UP`. A cold start takes 3–5 minutes.
- **Cloudflare Worker** (the watchdog). It wakes the service only for a wake credential: the `X-Sonar-Wake-Key` header, or a `JWT-SESSION` cookie whose HS256 signature and `exp` it verifies. The verification uses the session key SonarQube gets as `sonar.auth.jwtBase64Hs256Secret`, which also keeps browser sessions alive across cold starts. When the origin is down, the Worker signs `SetDesiredCapacity=1` with a scoped IAM user key and returns `503` with `Retry-After`. It never modifies forwarded requests.
- **EC2 Auto Scaling group** `sonarqube`. Spot only, with min 0, max 1 and subnets in every us-east-1 AZ. Capacity rebalancing is off, so two instances never share the tunnel or the database. OpenTofu must never manage `desired_capacity`.
- **Idle scale-in.** The instance does it itself. After 30 minutes without an access-log line that SonarQube authenticated (`%reqAttribute{LOGIN}` not `-`), and with no busy CE, it only calls `set-desired-capacity 0`. The services then stop through the OS shutdown, so a failed call never leaves a stopped but running instance.
- **Boot gate.** cloudflared, the only way in from outside, starts only after the boot script has changed `admin/admin` to the SSM password over localhost and verified the change.
- **Instance role.** A narrow inline Session Manager policy only. Never attach `AmazonSSMManagedInstanceCore`, which can read every SSM parameter in the account.
- **Aurora Serverless v2 PostgreSQL 17.x** with auto-pause (min 0 ACU). The instance is stateless, and Elasticsearch reindexes from the database on boot.
- **OpenTofu** owns every AWS and Cloudflare resource, including the Worker deploy. Wrangler is a root dev dependency used only for `npx wrangler tail sonarqube` (live Worker logs). Never deploy or change the Worker with it. State lives in S3 with a native lock file, and apply runs from this Mac.
- **Packaging.** `worker/src/index.js` is a single dependency-free module (SigV4 and HS256 through WebCrypto) that OpenTofu uploads as-is, so there is no build step. The user data is a prelude of `export` lines followed by `instance/boot.sh` read with `file()`. Never use `templatefile`, because `boot.sh` contains `${…}`. `boot.sh` requires its inputs at the top with `: "${VAR:?}"` lines.

## Constraints that shape the design

- Aurora only auto-pauses when it has zero connections. SonarQube keeps a connection pool open, so the database pauses only after the instance is gone. Any extra long-lived client (monitoring, a bastion) keeps it running and billing.
- Sonar does not test on Aurora. Stay on Aurora PostgreSQL 17.x: Community Build supports PostgreSQL 13–17, and support for 18 depends on the release.
- Community Build analyzes the main branch only and does not decorate PRs. The reusable workflow therefore runs on pushes to the default branch.
- SonarQube skips user-session setup for `/api/system/status`, `/api/authentication/validate` and the other URLs in `UserSessionInitializer.SKIPPED_URLS`, so they log `LOGIN` as `-` and never count as activity. That's why the scan heartbeat calls `/api/users/current`.
- Elasticsearch needs host sysctls `vm.max_map_count >= 524288` and `fs.file-max >= 131072`, set in the instance user data.
- Everything lives in `us-east-1`, in the dedicated member account `sonarqube` (`368861736633`, OU `Workloads`), through the IAM Identity Center profile `sonarqube` (SSO session `macbook-pro`). The default profile points to the organization's management account, and nothing here may use it. Both OpenTofu roots pin `profile = "sonarqube"` and `allowed_account_ids`, and every local `aws` command passes `--profile sonarqube`. Agent tooling that can't select a profile, such as an AWS MCP server bound to the default credentials, reaches the management account, not this stack. Only `FullAWSAccess` SCPs and RCPs apply, so nothing limits Spot, IAM or Regions. The "new AWS experience" restrictions in the `~/Projects/aws` project's agent guidance do not apply (checked 2026-10-27).
- Only the management account can activate the `Project` cost allocation tag. It stays active there, and the budget's tag filter depends on it. It is not managed in this repo.
- Since 2026-10-27 the organization's declarative EC2 policy `ec2-baseline` sets VPC Block Public Access to block internet gateway traffic in both directions. The `allow-bidirectional` exclusions on the public subnets (A16) are the only thing that lets the instance reach SSM, the package repositories, Docker Hub and Cloudflare. Without them the instance boots with no egress and never comes up. `allow-egress` is not enough: it only covers NAT gateways and egress-only internet gateways, and a public-IP instance behind an internet gateway stays blocked. Inbound protection comes from the security group, which has no ingress rules.
- All work in this repo is Tier 2 (infra, IAM, CI) and goes through `/spec`.
