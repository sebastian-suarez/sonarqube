# Plan: sonarqube-platform

The spec is `spec.md`; this file says how.

## Approach

The request path is caller → Worker on H → Cloudflare Tunnel → cloudflared on the Spot instance → SonarQube container → Aurora.

- **Waking.** When nothing is connected to the tunnel, Cloudflare answers the Worker's origin fetch with 530. If the request carries a wake credential, the Worker calls `SetDesiredCapacity=1`, signed with SigV4 through WebCrypto (no npm runtime dependencies). It checks the wake key with `crypto.subtle.timingSafeEqual`, and the session JWT with `crypto.subtle.verify` (HMAC-SHA256), checking `alg` and `exp` first. The group launches into whichever AZ subnet has Spot capacity, using `price-capacity-optimized` allocation.
- **Spot interruption.** The group replaces an interrupted instance on its own, since desired capacity stays 1. The Worker only matters once the group is at 0.
- **Boot.** User data reads the SSM secrets and installs Docker and cloudflared. It waits for Aurora (an auto-paused cluster resumes on the first connection, in about 15 s), then starts SonarQube with the shared session key. It runs the admin bootstrap over localhost and starts cloudflared only if the bootstrap verifies. Elasticsearch data is ephemeral and reindexes from the database at startup.
- **Idle.** A Python checker (standard library only) runs on a systemd timer every 5 minutes. It counts access-log lines that SonarQube authenticated (`%reqAttribute{LOGIN}` not `-`) and reads `api/ce/activity_status` (as `admin`, with the SSM password). When idle, it only calls `set-desired-capacity 0`. Termination then stops the systemd units, and the SonarQube container gets 120 s to stop. If the call fails, nothing has been stopped and the next run retries.
- **Packaging.** The Worker is a single dependency-free ES module, `worker/src/index.js`, which OpenTofu's `cloudflare_workers_script` uploads as-is. There is no bundler or build step, so `tofu plan` never needs build output. The boot logic lives in `instance/boot.sh` (shellchecked). OpenTofu renders the user data as a prelude of variables plus `boot.sh` and the embedded `idle_check.py`, and keeps the raw user data under the 16 KB EC2 limit.
- **Provider pins.** `hashicorp/aws` 6.70.0, `cloudflare/cloudflare` 5.28.1 and `hashicorp/random` 3.9.1, exact versions. The latest releases on 2026-10-26, mirrored at `~/.cache/routing/sonarqube/tofu-mirror` for sandboxed writers (`TF_CLI_CONFIG_FILE=~/.cache/routing/sonarqube/tofu-mirror/tofurc`).
- **Cloudflare auth.** OpenTofu reads `CLOUDFLARE_API_TOKEN` from the environment. The token is scoped to:
  - Zone DNS Edit and Workers Routes Edit on the zone
  - Account Workers Scripts Edit and Cloudflare Tunnel Edit
- **Cost.** At about 30 active hours a month, the estimate is $3–5 a month:

  | Item | Cost |
  | --- | --- |
  | Spot compute | $0.40–1.00 |
  | Public IPv4 while running | $0.15 |
  | Aurora at 0.5–1 ACU | $1.80–3.60 |
  | Aurora storage | under $0.50 |
  | S3 | cents |
  | SSM standard parameters, budget, Cloudflare Workers free plan and Tunnel | $0 |

## Files

| Path | Route | Writer |
| --- | --- | --- |
| `tests/`, `worker/test/`, `instance/tests/`, `infra/tests/` | coding.overflow | tests writer (protected after `spec.sh ready`) |
| `infra/bootstrap/*.tf` | coding.default | infra writer |
| `infra/*.tf` (user data prelude and assembly) | coding.default | infra writer |
| `worker/src/index.js` | coding.default | worker writer |
| `instance/idle_check.py`, `instance/boot.sh` | coding.default | instance writer |
| `scripts/wake.sh`, `scripts/scan.sh`, `scripts/onboard.sh`, `.github/workflows/sonarqube-scan.yml`, `docs/caller-workflow.yml`, `README.md` | coding.default | tooling writer |
| `.gitignore`, `.editorconfig` | hub (gitignore skill) | hub |

## Risks

- **The zone is unverified.** `sebastiansuarez.dev` is assumed to be a Cloudflare zone in the user's account, because the `cf` CLI isn't installed to check. Task 2 verifies it before any apply.
- **Aurora is untested by Sonar.** It is PostgreSQL-compatible, and 17.x is within Community Build's supported 13–17. G1–G3 are the proof.
- **No Spot capacity means no service.** If none of the six types has capacity in any AZ, the service stays down (on-demand fallback is a non-goal). The Worker keeps answering `WAKING`.
- **Cold start takes 3–5 minutes:** Spot launch, Docker install and image pull, then SonarQube start. Private repos are billed for the CI minutes spent waiting. A baked AMI would cut this; it is a non-goal for now.
- **Wake during termination.** The Worker only wakes the service when the origin is down. During termination, cloudflared and SonarQube stop together at OS shutdown, and a new instance needs minutes to boot. So the old and new SonarQube never serve at the same time, though their EC2 lifetimes can overlap for a moment.
- **Secrets sit in OpenTofu state:** the Worker's IAM key, the wake key and the session key. The state bucket is private and encrypted. To rotate, run `tofu apply -replace=<resource>`. After rotating the wake key, rerun `onboard.sh` for each repo. Rotating the session key logs out every browser.
- **A logged-out session can still wake the service until its `exp`** (the SonarQube default session timeout is 3 days). It doesn't count as activity, so each such wake costs at most about 35 minutes of runtime.
- **A failed CE call counts as not busy.** If SonarQube stops answering in the middle of a long CE task, with no authenticated request for 30 minutes, the instance scales in and the task must be rerun.
- **T-family Spot instances run in unlimited CPU credit mode.** Boot bursts add a small surplus charge.
- **Tag-filtered budget data lags.** Data for a newly activated cost allocation tag can take up to 24 hours, so the budget reads $0 at first.
- **Long analyses.** The heartbeat keeps the server up through the scanner's local phase, and the CE check keeps it up while a task is pending or running. If the heartbeat dies (for example, network loss on the CI runner) during a silent phase over 30 minutes, the upload fails and the scan must be rerun. The upload carries only the token, so it can't wake the service.

- **VPC Block Public Access (v3).** The organization's `ec2-baseline` policy blocks internet gateway traffic in both directions. The public subnets carry `allow-bidirectional` exclusions, and if the organization ever disables exclusions, the instance loses egress and the service can't start. The exclusions take a few minutes to become active after creation.

## Verification

```sh
tofu -chdir=infra fmt -check -recursive
tofu -chdir=infra init -backend=false && tofu -chdir=infra validate && tofu -chdir=infra test
tofu -chdir=infra/bootstrap init -backend=false && tofu -chdir=infra/bootstrap validate
npm --prefix worker test
python3 -m unittest discover -s instance/tests
python3 -m unittest discover -s tests/scripts
python3 -m unittest discover -s tests/workflow
shellcheck scripts/*.sh instance/*.sh
actionlint .github/workflows/*.yml docs/caller-workflow.yml
```

Run group G after the first apply, with the user's go, and log each run in `log.md`.
