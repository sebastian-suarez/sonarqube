# SonarQube

A single-user SonarQube Community Build at `https://sonar.sebastiansuarez.dev`, for GitHub Actions and for local scans of checkouts in `~/Projects`. It runs on one AWS Spot instance with Aurora Serverless v2 behind a Cloudflare Worker and Tunnel. It scales to zero after 30 minutes without signed-in activity, and wakes when a caller presents the wake key or a valid session cookie. At about 30 active hours a month it costs roughly $3–5.

The design, acceptance criteria and decisions live in [`docs/specs/sonarqube-platform/`](docs/specs/sonarqube-platform/).

## Requirements

- OpenTofu, AWS CLI v2 and its Session Manager plugin, GitHub CLI (`gh auth login`) and curl.
- An AWS CLI profile named `sonarqube` (IAM Identity Center) for the dedicated `sonarqube` member account, where the stack lives. In `~/.aws/config`, with `<session>` the name of your `[sso-session]` section:

  ```ini
  [profile sonarqube]
  sso_session = <session>
  sso_account_id = 368861736633
  sso_role_name = AdministratorAccess
  region = us-east-1
  ```

  Sign in with `aws sso login --profile sonarqube`.
- Docker, for local scans.
- macOS: the scripts keep the analysis token and the wake key in the login Keychain.

## Infrastructure setup

The stack lives in the `sonarqube` member account. Both OpenTofu roots pin the `sonarqube` profile and only accept account `368861736633`, so they fail instead of falling back to the default profile.

1. Create a Cloudflare API token with these permissions and export it as `CLOUDFLARE_API_TOKEN`:
   - Zone `sebastiansuarez.dev`: DNS Edit and Workers Routes Edit
   - Account: Workers Scripts Edit and Cloudflare Tunnel Edit
2. Create the state bucket. Pick a globally unique `bucket_name`, such as `sonarqube-tofu-state-368861736633`; the bootstrap root keeps its own state locally in `infra/bootstrap/` (gitignored).

   ```sh
   tofu -chdir=infra/bootstrap init
   tofu -chdir=infra/bootstrap apply -var bucket_name=<bucket_name>
   ```

3. Set the main root's two variables. `*.tfvars` is gitignored, so either keep a local `infra/terraform.tfvars`:

   ```hcl
   cloudflare_account_id = "0c0ba106c84a11573f6a720e162ba6e9"
   cloudflare_zone_id    = "ed1796dc7261c72ff630e77a212d03ff"
   ```

   or export `TF_VAR_cloudflare_account_id` and `TF_VAR_cloudflare_zone_id` with the same values.
4. Initialise the main root against the bucket, then apply:

   ```sh
   tofu -chdir=infra init -backend-config="bucket=<bucket_name>"
   tofu -chdir=infra apply
   ```

The group starts at zero instances; the first wake boots one.

The budget's filter depends on the `Project` cost allocation tag, which is activated once in the organization's management account because member accounts can't activate it. While the tag is inactive, the budget sees $0 and never alerts. With management-account credentials, `aws ce list-cost-allocation-tags --tag-keys Project` shows its status, and `aws ce update-cost-allocation-tags-status --cost-allocation-tags-status TagKey=Project,Status=Active` activates it. A new tag key only shows up there up to 24 hours after the first tagged usage.

If the account's organization enforces VPC Block Public Access, for example through an EC2 declarative policy, that policy must allow exclusions. The stack excludes its public subnets in `allow-bidirectional` mode, because `allow-egress` doesn't cover an instance with a public IPv4 address behind an internet gateway. Inbound traffic stays closed by the instance security group, which has no ingress rules.

Aurora takes automatic minor upgrades, and OpenTofu ignores the resulting `engine_version` drift. Editing `engine_version` in `infra/database.tf` therefore never upgrades the cluster: upgrade with `aws rds modify-db-cluster --profile sonarqube --db-cluster-identifier sonarqube --engine-version <version> --apply-immediately`, then set the same value in the file.

## Onboarding a repository

```sh
scripts/onboard.sh owner/repo
```

It needs live `aws` and `gh` sessions. Each run:

1. Copies the wake key from SSM (`/sonarqube/wake-key`) into the Keychain item `sonarqube-wake-key`.
2. On the first run only, when the Keychain has no `sonarqube-analysis-token`: wakes the server, creates a global analysis token as `admin` (password from `/sonarqube/admin-password`) and stores it there.
3. Sets the repository secrets `SONAR_TOKEN` and `SONAR_WAKE_KEY`.
4. Prints the caller workflow ([`docs/caller-workflow.yml`](docs/caller-workflow.yml)).

Commit that workflow as `.github/workflows/sonarqube.yml` in the repository, replacing `main` if its default branch differs. The script never commits, pushes or opens pull requests. Scans run only on the default branch (Community Build has no branch analysis), and the project key is the repository name unless the caller passes `with: project-key: …`. The reusable workflow waits up to 15 minutes for the server to wake, starts a heartbeat, then runs the pinned scan action.

## Waking

```sh
scripts/wake.sh
```

It polls `/api/system/status` with the wake key from the Keychain until SonarQube reports `UP`. A cold start takes 3–5 minutes. `SONAR_WAIT_SECONDS` (default 900) bounds the wait and `SONAR_POLL_SECONDS` (default 5) sets the interval.

For the web UI, wake it first, then sign in as `admin` with:

```sh
aws ssm get-parameter --profile sonarqube --name /sonarqube/admin-password --with-decryption --query Parameter.Value --output text
```

A signed-in browser wakes the service on its own later: the Worker accepts its session cookie until it expires.

To watch the Worker's requests live, for example when a wake doesn't happen, run `npm install` once in the repo root, then:

```sh
CLOUDFLARE_API_TOKEN=<token> CLOUDFLARE_ACCOUNT_ID=<account id> npx wrangler tail sonarqube --format pretty
```

Wrangler is only used for logs. OpenTofu deploys the Worker.

## Local scans

From anywhere inside a checkout, clean and on its default branch:

```sh
~/Projects/sonarqube/scripts/scan.sh
```

It refuses to run off the default branch (`origin/HEAD`, else `init.defaultBranch`, else `main`) or with uncommitted or untracked changes. It uses the same project key as CI: the name of the `origin` repository, or the folder name without an origin. It wakes the server, sends an authenticated heartbeat every `SONAR_HEARTBEAT_SECONDS` (default 300) so a long analysis doesn't count as idle, and runs `sonarsource/sonar-scanner-cli` with the checkout mounted read-only. It exits with the scanner's status. The token comes from the Keychain, so run `onboard.sh` once for any repository first. Per-project scanner settings go in a `sonar-project.properties` at the repository root.

## Upgrades

Upgrades are manual. To move SonarQube to a new version:

1. Take a manual snapshot of the Aurora cluster.
2. Bump the `sonarqube:<version>-community` image tag in `infra/` and run `tofu -chdir=infra apply`.
3. Boot an instance on the new launch template: end the running one with `aws autoscaling terminate-instance-in-auto-scaling-group --profile sonarqube --instance-id <instance-id> --no-should-decrement-desired-capacity`, or, when the group is at zero, run `aws autoscaling set-desired-capacity --profile sonarqube --auto-scaling-group-name sonarqube --desired-capacity 1`. `aws autoscaling describe-auto-scaling-groups --profile sonarqube --auto-scaling-group-names sonarqube --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text` prints the instance ID.
4. When the schema changes, the new version waits in `DB_MIGRATION_NEEDED`, and cloudflared starts only once SonarQube is `UP`, so run the migration over Session Manager. Stop the idle timer first, or it scales the group to zero after 30 minutes:

   ```sh
   aws ssm start-session --profile sonarqube --target <instance-id>
   sudo systemctl stop sonarqube-idle.timer
   curl -fsS -X POST http://localhost:9000/api/system/migrate_db
   # when http://localhost:9000/api/system/status reports UP:
   sudo systemctl start sonarqube-idle.timer
   ```

The scanner image tag lives in `scripts/scan.sh`, and the actions in `.github/workflows/sonarqube-scan.yml` are pinned to commit SHAs; bump them by hand.

## Rotating secrets

Replace the secret's resource, then refresh whatever holds a copy:

- Wake key: `tofu -chdir=infra apply -replace=random_password.wake`, then rerun `scripts/onboard.sh owner/repo` for every onboarded repository. Each run refreshes the Keychain and that repository's `SONAR_WAKE_KEY`.
- Session key: `tofu -chdir=infra apply -replace=random_bytes.jwt`. SonarQube reads it at boot, so every browser is signed out once the next instance starts.
- Worker access key: `tofu -chdir=infra apply -replace=aws_iam_access_key.worker`.

Don't replace `random_password.admin` this way. The boot gate checks the SSM password against SonarQube's database and keeps cloudflared stopped when they differ.

## Teardown

The Aurora cluster has deletion protection and takes a final snapshot when it's deleted.

1. Turn deletion protection off. `tofu -chdir=infra state show aws_rds_cluster.sonarqube` shows the cluster identifier.

   ```sh
   aws rds modify-db-cluster --profile sonarqube --db-cluster-identifier <cluster> --no-deletion-protection --apply-immediately
   ```

2. Run `tofu -chdir=infra destroy`. The final snapshot stays in RDS until you delete it. Delete it before tearing down a second time, because its name `sonarqube-final` is fixed.
3. To remove the state bucket too, empty it (all object versions), then run `tofu -chdir=infra/bootstrap destroy -var bucket_name=<bucket_name>`.
4. Delete the Keychain items `sonarqube-analysis-token` and `sonarqube-wake-key`, and the `SONAR_TOKEN` and `SONAR_WAKE_KEY` secrets in onboarded repositories.
