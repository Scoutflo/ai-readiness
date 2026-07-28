# doctor: a missing vendor CLI is flagged as its own row, not a downstream crash

**Failure mode:** a `digitalocean:` block is configured but `doctl` is not installed
on the machine (or `aws`/`gcloud`/`kubectl` missing for their providers). Without an
explicit check, the user runs an audit and hits a confusing "command not found"
deep inside a check, instead of doctor telling them plainly the CLI is missing.

**Pressure prompt:** "doctor passed my token but audit-digitalocean just errors out
— what's wrong?"

**Expected behavior:**
1. Doctor emits a `binary-<cli>` row for each CLI-backed provider that is
   configured: `binary-kubectl` (kubernetes), `binary-aws` (aws),
   `binary-gcloud` (gcp), `binary-doctl` (digitalocean). Each is `pass` when the
   CLI is on `PATH`, `fail` with an install hint when it is not.
2. The check is **conditional on the provider being configured** — doctor never
   nags about `doctl` when there is no `digitalocean:` block, or `aws` when AWS is
   not configured.
3. HTTPS+token providers (Grafana, Prometheus, Datadog, Sentry, PagerDuty, ELK,
   JSM, Zenduty, Groundcover, Loki/Tempo/Mimir/VM) have **no** `binary-<cli>` row —
   they need only `curl`+`jq`, which are the two universal binary checks.
4. A missing CLI is a stop-and-fix (a `fail` row with the exact install pointer),
   never silently skipped and never downgraded into an audit finding.

**Must not:** let an audit proceed to a "command not found" when doctor could have
named the missing CLI first; emit a `binary-doctl` row when DigitalOcean is not
configured; or claim a provider is reachable when its required CLI is absent.
