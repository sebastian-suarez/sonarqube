# Offline acceptance contract

Run `bash tests/run-acceptance.sh` from any directory. Groups A–F are offline; G is excluded. Node 24, Python stdlib, Ruby YAML, OpenTofu, shellcheck and actionlint are required. The runner inherits `TF_CLI_CONFIG_FILE`; it never selects a mirror or contacts a cloud API. Missing implementation is a failure. It continues through all groups. A and F share the result of the single `tofu test` invocation.

## Infrastructure

Main root: `infra/`; state root: `infra/bootstrap/`. Pin exactly `hashicorp/aws = 6.70.0`, `cloudflare/cloudflare = 5.28.1`, `hashicorp/random = 3.9.1` in the main root. Bootstrap pins `hashicorp/aws = 6.70.0` in its own `providers.tf` and uses the same default Project tag. Put the main `required_providers` and AWS provider in `providers.tf`, with `source` immediately before `version` in each provider entry. In both roots, `provider "aws"` sets literal `profile = "sonarqube"` and `allowed_account_ids = ["368861736633"]` before `default_tags`. Use literal `region = "us-east-1"` and `default_tags { tags = { Project = "sonarqube" } }`. ASG also needs an explicit propagated Project tag.

The main root accepts `cloudflare_account_id` and `cloudflare_zone_id` strings, with no other required inputs. Bootstrap accepts `bucket_name`. Cloudflare auth comes from its usual environment variable. Tests supply fake account/zone IDs, three AZs, caller account `123456789012`, an AL2023 AMI, random values and a tunnel token. All runs use mock providers. A12 and F2 use `command = apply` because OpenTofu reads the tunnel-token data source only at apply while its tunnel is pending creation; every other run uses `command = plan`. Never require credentials or real provider data in these runs.

Use these root addresses. Extra supporting resources are allowed, but cannot introduce extra instances, IAM permissions, ingress or routes contradicting the tests. Asserted resources cannot be hidden in child modules.

| Address | Interface |
| --- | --- |
| `data.aws_availability_zones.available` | `state = "available"`, `opt-in-status = ["opt-in-not-required"]` filter |
| `data.aws_ssm_parameter.al2023` | `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` |
| `data.aws_caller_identity.current` | Account ID for parameter ARNs |
| `aws_vpc.main`, `aws_internet_gateway.main` | Main VPC and public gateway |
| `aws_subnet.public`, `aws_subnet.private` | `for_each` maps keyed by AZ name; public map covers every returned AZ |
| `aws_vpc_block_public_access_exclusion.public` | `for_each` map keyed like `aws_subnet.public`; `subnet_id` only (no `vpc_id`), mode `allow-bidirectional`; no exclusion for private subnets or the VPC |
| `aws_route_table.public`, `aws_route_table.private` | Inline routes; public default route to IGW; private `route = []` |
| `aws_route_table_association.public`, `.private` | Maps keyed by the respective subnet AZs |
| `aws_security_group.instance`, `.database` | Inline ingress, explicitly empty on instance; database exactly TCP 5432 from instance SG |
| `aws_autoscaling_group.sonarqube` | In `asg.tf`; name `sonarqube`; omit desired_capacity assignment and ignore it in lifecycle |
| `aws_launch_template.sonarqube` | One `/dev/xvda` root mapping; public IPv4 and instance SG in first network interface; base64 user_data |
| `aws_rds_cluster.sonarqube`, `aws_rds_cluster_instance.sonarqube` | One unindexed cluster instance |
| `aws_db_subnet_group.sonarqube` | All private subnet IDs |
| `aws_iam_user.worker`, `aws_iam_user_policy.worker`, `aws_iam_access_key.worker` | One inline user policy and one key |
| `aws_iam_role.instance`, `aws_iam_role_policy.instance` | Separate inline policy; no inline_policy blocks or managed policy attachments |
| `random_password.db`, `.admin`, `.wake`, `random_bytes.jwt` | Wake length >=32; JWT length exactly 32 bytes |
| `aws_ssm_parameter.db_password`, `.admin_password`, `.tunnel_token`, `.wake_key`, `.jwt_secret` | SecureString at the spec's exact paths, sourced from random values/tunnel token |
| `cloudflare_zero_trust_tunnel_cloudflared.sonarqube` | Tunnel |
| `data.cloudflare_zero_trust_tunnel_cloudflared_token.sonarqube` | Token of that tunnel |
| `cloudflare_zero_trust_tunnel_cloudflared_config.sonarqube` | `config.ingress`: hostname rule then 404 rule |
| `cloudflare_dns_record.sonar` | Proxied CNAME; name `sonar` or full hostname |
| `cloudflare_workers_script.sonarqube` | `script_name`, `bindings` with `type`, `name`, `text`; types `secret_text` / `plain_text` |
| `cloudflare_workers_route.sonar` | Spec hostname pattern, `script` points to script_name |
| `aws_budgets_budget.sonarqube` | `TagKeyValue = ["user:Project$sonarqube"]`; two GREATER_THAN, PERCENTAGE notifications |
| `aws_resourcegroups_group.sonarqube` | Name `sonarqube`; `TAG_FILTERS_1_0` query for `AWS::AllSupported` with `Project=sonarqube` |

Neither root declares an `aws_ce_cost_allocation_tag` resource; cost allocation tag activation belongs to the management account.

IAM JSON uses `Statement`, `Action` and `Resource` arrays, including singleton actions/resources. Instance policy has exactly three statements corresponding to A10's three bullets. Do not use standalone `aws_security_group_rule`, `aws_vpc_security_group_ingress_rule` or `aws_route` resources: inline policies allow the tests to inspect the whole rule set. Main `backend.tf` contains an S3 backend with literal `region = "us-east-1"`, `profile = "sonarqube"` and `use_lockfile = true`.

Bootstrap addresses are `aws_s3_bucket.state`, `aws_s3_bucket_versioning.state`, `aws_s3_bucket_public_access_block.state`, `aws_s3_bucket_server_side_encryption_configuration.state`. Versioning Enabled; all four public access blocks true; default encryption AES256 or aws:kms. Its test selects `module { source = "./bootstrap" }`.

## Worker

`worker/src/index.js` exports default `{ fetch(request, env, ctx) }`. Env names: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ASG_NAME`, `AWS_REGION`, `WAKE_KEY`, `JWT_SECRET`. The latter is base64 and must be decoded before HS256 verification. `ctx.waitUntil` is available and drained by the tests. All outbound fetches, both origin and AWS, go through `globalThis.fetch`. No other network mechanism is allowed. Tests supply a timingSafeEqual shim for the runtime-specific crypto method.

`worker/package.json` stays ES module (`type: module`) and `scripts.test` is `node --test test/*.test.js`. Implementers may add build scripts and dependencies. Tests recompute the sent SigV4 signature using its actual SignedHeaders; they do not prescribe a signed-header set. The checker is calibrated against the published IAM ListUsers AKIDEXAMPLE vector, then used on a fixed-date Auto Scaling POST.

## Idle checker and logs

`python3 instance/idle_check.py` is a one-shot process. Return 0 for idle-success or not-idle; return nonzero for a failed AWS scale-in. Read files directly and call the CE endpoint using the standard library. No aws call is needed to retrieve the password: boot supplies a local password file. Only idle may invoke the exact C5 command. Never stop services.

| Environment | Production default | Test use |
| --- | --- | --- |
| `SONAR_ACCESS_LOG` | `/var/log/sonarqube/access.log` | Temporary log |
| `SONAR_UPTIME_FILE` | `/proc/uptime` | Linux-format uptime file |
| `SONAR_ADMIN_PASSWORD_FILE` | `/run/sonarqube/admin-password` | Plaintext admin password, optional terminal newline |
| `SONAR_CE_URL` | `http://localhost:9000/api/ce/activity_status` | Loopback HTTP stub |
| `SONAR_CE_TIMEOUT_SECONDS` | `5` | `0.1`; positive decimal seconds |
| `SONAR_NOW_EPOCH` | Current system time when unset | Fixed epoch for log-window tests |

CE requests use HTTP Basic `admin:<password>` and User-Agent `sonarqube-idle-check`. A non-200 response, refusal or timeout counts as not busy. Uptime's first field is seconds since boot. Thresholds are 1800 seconds; tests avoid the unspecified exact log-window boundary. An empty log is no activity.

The exact access pattern, shared by rendered boot assertions and C fixtures, is:

```text
%h %l %reqAttribute{LOGIN} [%t{dd/MMM/yyyy:HH:mm:ss Z}] "%r" %s %b "%i{User-Agent}"
```

Example:

```text
127.0.0.1 - owner [26/Oct/2026:12:00:00 +0000] "GET /api/system/status HTTP/1.1" 200 2 "scanner"
```

Only the third field is LOGIN. The quoted final field is the User-Agent. An unauthenticated line has `-` as LOGIN.

## Rendered boot interface

Keep secrets out of rendered user data. Fetch the four instance-consumed SSM parameters at boot into `DB_PASSWORD`, `ADMIN_PASSWORD`, `TUNNEL_TOKEN`, `JWT_SECRET`. Include the lowercase property `sonar.auth.jwtBase64Hs256Secret` and its runtime `$JWT_SECRET` reference on the same line. The JDBC URL contains the cluster writer endpoint and port 5432. Use the exact log pattern above as literal text.

Persist sysctls in `/etc/sysctl.d/99-sonarqube.conf` and apply with `sysctl --system`. Bound the database TCP wait using `timeout 180` around a `/dev/tcp/.../5432` retry loop. After this succeeds, use `systemctl start sonarqube` as the sole start of the SonarQube unit. Container `--stop-timeout` is numeric seconds >=120; the first numeric `TimeoutStopSec=` in rendered data exceeds that value. Store the password at `/run/sonarqube/admin-password`, mount access.log at `/var/log/sonarqube/access.log`, and install `/usr/local/bin/idle_check.py` with `ExecStart=/usr/bin/python3 /usr/local/bin/idle_check.py`, `sonarqube-idle.timer` with `OnBootSec=5min`, `OnUnitActiveSec=5min`, and run `systemctl enable --now sonarqube-idle.timer` before the admin gate. cloudflared's command reads `$TUNNEL_TOKEN` at runtime.

Define shell functions `admin_authenticates()` and `change_admin_password()`. The first authenticates `admin:$1` over `/api/authentication/validate` and checks `valid: true`; the second changes admin's password over `/api/users/change_password`, with `previousPassword=admin` and `password=$ADMIN_PASSWORD`. These localhost URLs and `http://localhost:9000/api/system/status` appear literally in rendered data. After the timer is enabled and a loop has observed `UP`, use this exact gate, including its diagnostics:

```sh
if admin_authenticates admin; then
  change_admin_password || { echo "admin password change failed" >&2; exit 1; }
fi
if admin_authenticates "$ADMIN_PASSWORD" && ! admin_authenticates admin; then
  systemctl start cloudflared
else
  echo "admin bootstrap verification failed; cloudflared remains stopped" >&2
fi
```

This is the sole start of cloudflared; no enable-with-now/restart or automatic boot start may bypass it. F checks inspect rendered shell structure, not execution on an OS. Live startup, database compatibility and actual gate behavior remain G's responsibility.

## Local scripts

Entry points: `bash scripts/wake.sh`, `bash scripts/scan.sh`, `bash scripts/onboard.sh owner/repo`. Scripts work from a caller checkout outside this repository and locate sibling scripts/docs relative to themselves. All URLs use the spec's base URL. Read each Keychain item with `security find-generic-password -s <service> -a "$USER" -w`. To update without exposing secrets in argv, invoke `security -i` and pass a shell-quoted `add-generic-password -U -s <service> -a <account> -w <value>` command on stdin (optional `quit` line). Both service names are exactly those in the spec.

| Knob | Default | Contract |
| --- | --- | --- |
| `SONAR_WAIT_SECONDS` | `900` | Positive integer deadline; tests use 1 or 2 |
| `SONAR_POLL_SECONDS` | `5` | Positive decimal sleep; tests use 0.02 |
| `SONAR_HEARTBEAT_SECONDS` | `300` | Positive decimal sleep; short scans use 0.05; D9 uses 1 |

Every `aws` call in `onboard.sh` carries `--profile sonarqube` after the subcommand (`aws ssm get-parameter --profile sonarqube …`).

Pass all curl secrets through `curl -K -` config stdin; token generation uses Basic `admin:<password>` there and sends `type=GLOBAL_ANALYSIS_TOKEN` as form data. SSM reads use `aws ssm get-parameter --profile sonarqube --name <path> --with-decryption --query Parameter.Value --output text`. `gh secret set <name> -R owner/repo` receives the raw value on stdin. Pass the scanner token as inherited `SONAR_TOKEN`, using Docker `-e SONAR_TOKEN`, with no value in argv. SONAR_HOST_URL may be an explicit Docker env value or inherited by name. Use an exact scanner version beginning with a digit. The actual repository root is mounted `:ro` or with `--mount ... readonly`. Scanner receives `-Dsonar.projectKey=<key>`.

Git stubs support `rev-parse --show-toplevel`, `--is-inside-work-tree`, `--abbrev-ref HEAD`; `branch --show-current`; `symbolic-ref [--quiet] [--short] refs/remotes/origin/HEAD` or HEAD; `config [--get] remote.origin.url`/`init.defaultBranch`; `remote get-url origin`; `status --porcelain`; `diff [--cached] --quiet`; `ls-files --others --exclude-standard`. Prefer status --porcelain for both tracked and untracked dirt. An absent origin or config returns nonzero. Origin HEAD takes priority over config, then main.

Heartbeat cleanup must finish before scan.sh returns, on scanner success and failure. Tests run scripts in an isolated process group, check that no live descendant remains, and kill any leak for cleanup. Each subprocess test has a 5-second ceiling; D9's scanner lasts 3 seconds. No token/key/password may occur in any recorded git/curl/docker/gh/security/aws argv. No git commit/push or gh pr/repo invocation is allowed.

## Workflow structure

Reusable workflow: `.github/workflows/sonarqube-scan.yml`, job `scan`, ordered step IDs `wake`, `heartbeat`, `scan`. Use E3's expression literally apart from whitespace/expression delimiters. Set scan `with.args` to include `-Dsonar.projectKey=${{ inputs.project-key || github.event.repository.name }}`. Every `uses:` reference in the reusable workflow is a full 40-character SHA. Checkout has fetch-depth 0.

Wake step has `timeout-minutes: 15` (or less), a poll loop, a sleep, an UP condition, the literal status URL and X-Sonar-Wake-Key; `env.SONAR_WAKE_KEY: ${{ secrets.SONAR_WAKE_KEY }}`. Platform timeout must fail the step; no continue-on-error. Heartbeat has a background loop with a trailing `&`, literal `/api/users/current` URL, bearer header through `curl -K -`, sleep of 1..300 seconds or `$SONAR_HEARTBEAT_SECONDS`, and the token via env. If an interval env is supplied it is numeric and <=300. Never place a secrets expression inside any run script. The scan action gets the token and base URL through env.

The caller example uses `push.branches: [main]` and workflow_dispatch, the exact @main reusable-workflow reference and explicit secret mappings. Owners whose default branch differs must change main in that example.

## Coverage index

Each ID below is asserted; A1/A2/D1/E1 are commands in the runner. A3 is the full tofu test invocation. Run names contain the criteria they assert.

| Criterion | Test |
| --- | --- |
| A3 | runner: tofu test; all HCL runs |
| A4 | acceptance.tftest.hcl: A3_A4_single_instance_and_unmanaged_desired_capacity |
| A5 | A5_spot_policy_and_exact_instance_types |
| A6 | A6_public_subnet_in_each_available_az |
| A7 | A7_hardened_launch_template |
| A8 | A8_private_aurora_17_autopause_and_data_guards |
| A9 | A9_worker_iam_exactly_one_scoped_action_and_key |
| A10 | A10_instance_iam_has_no_managed_or_overbroad_policies |
| A11 | A11_tunnel_dns_route_and_worker_bindings |
| A12 | A12_secure_parameters_and_shared_random_values |
| A13 | A13_tagged_monthly_budget_and_notifications |
| A14 | A14_main_backend_native_lock_and_region; bootstrap.tftest.hcl: A14_bootstrap_private_versioned_encrypted_state |
| A15 | A15_aws_region_and_default_project_tag |
| A17 | A17_tag_based_resource_group |
| B1 | acceptance.test.js: B1 B6 GET/POST authenticated=false/true |
| B2 | B2 B6 B7: each of 502/503/504/530/throw |
| B3 | B3 B6: each of 502/503/504/530/throw |
| B4 | B4: AWS 403/500/throw |
| B5 | B5: each forged/header/JWT variant |
| B6 | exercise request preservation in every Worker case; B1 and origin 401/403/404/429/500 |
| B7 | published vector checker and independently recomputed AWS request signatures |
| B8 | B8: independently signed HS256 cookie |
| C1 | test_C1_C6_recent_authenticated_activity; test_C1_C6_activity_before_noise_still_counts; test_C1_C6_activity_is_authentication_field_not_header_or_url |
| C2 | test_C2_C5_idle_ignores_unauthenticated_self_and_old_lines; test_C2_C5_empty_log_is_idle |
| C3 | test_C3_C6_pending_and_running_ce_are_busy |
| C4 | test_C4_C6_uptime_gate |
| C5 | C2/C7/C8 command transcripts include aws/systemctl/docker |
| C6 | C1/C3/C4 empty command transcripts |
| C7 | test_C7_failed_scale_in_retries_and_stops_nothing |
| C8 | test_C8_C5_failed_ce_counts_as_not_busy |
| D1 | runner: shellcheck scripts/*.sh instance/*.sh |
| D2 | test_D2_D8_wake_reads_keychain_and_polls; test_D2_D8_wake_has_bounded_timeout |
| D3 | test_D3_D8_off_branch/tracked_changes/untracked_changes tests |
| D4 | test_D4_D5_D8 clean/no-origin/fallback scans; test_D4_D8_wake_failure_prevents_scanner |
| D5 | three test_D4_D5_D8 project-key/default-branch cases |
| D6 | test_D6_D7_D8_onboarding_refreshes_stale_wake_key |
| D7 | preceding test; test_D7_D8_missing_token_is_created_after_wake |
| D8 | assert_D8 on every D2–D9 invocation, every recorded command and every fixture secret |
| D9 | test_D9_D8_heartbeat_success_cleanup; test_D9_D8_heartbeat_failure_cleanup |
| E1 | runner: actionlint .github/workflows/*.yml docs/caller-workflow.yml |
| E2 | test_E2_workflow_call_interface_and_project_key |
| E3 | test_E3_only_default_branch_scans |
| E4 | test_E4_full_checkout_and_sha_pins |
| E5 | test_E5_bounded_wake_before_scan |
| E6 | test_E6_caller_triggers_and_secret_mapping |
| E7 | test_E7_background_heartbeat_between_wake_and_scan |
| F1 | acceptance.tftest.hcl: F1_rendered_boot_configuration |
| F2 | F2_no_secrets_rendered_in_user_data |
| F3 | F3_verified_localhost_admin_gate_before_tunnel |

## Readings and offline limits

- A3's parenthetical lists A4–A17/F1–F3; the brief also asks A3 in run names, so the first run additionally names A3.
- Lifecycle/backend/provider configuration is not exposed as planned resource attributes. A4/A14/A15 therefore inspect the named configuration files; route and IAM inventory checks inspect root tf files. Formatting and the limited file/interface conventions above are part of this contract.
- D7 needs a Keychain write, while D8 forbids secret argv. Interactive security stdin is the reading that satisfies both.
- E6 has no portable literal for another repository's default branch in push.branches. The example assumes main; E3 still gates the reusable job against the actual default branch. E4's SHA rule applies to the reusable workflow, since E6 explicitly requires the caller's @main reference.
- F1's "SSM parameters" means the four consumed by the instance. The wake key is only consumed by the Worker/callers and is not fetched by boot.
- F3 is a rendered-shell assertion. The shared gate makes its branching inspectable; arbitrary shell behavior, real password changes and actual cloudflared isolation cannot be proven by text assertions. G remains required before claiming operational boot safety.
- No exact 1800-second access-log boundary was specified. Tests use 1799 and 1801 seconds, while uptime 1800 is explicitly accepted.
- Black-box credential cases cannot prove constant-time execution; they cover equality/rejection and the planned timingSafeEqual interface is available to implementations.
- The runner deliberately shares A/F status, so an unrelated infrastructure failure also marks F failed. Inspect individual tofu runs for precise attribution.

Provider-backed fixture evaluation and the CE HTTP stub require local socket binds. A sandbox that denies binds cannot complete those harness checks, even with the offline mirror. Re-run them in a socket-capable environment before protecting the suite.
