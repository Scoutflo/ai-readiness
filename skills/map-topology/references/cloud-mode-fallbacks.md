# Cloud Mode — denials, fallbacks, and workarounds (every "no" has a next move)

The operating rule for every permission failure, missing tool, or absent data
source in Cloud Mode: **never present a denial as a dead end.** The user is
told three things, in this order: what we CAN deliver right now, the single
smallest thing that would unlock more, and the workaround if that thing is not
possible. A reduced map that says exactly what it is beats a complete-looking
map built on guesses — and beats an error message by even more.

The message pattern (use it verbatim in spirit):

> "Here is what I can map with the current access: <the working lanes>.
> To also get <the missing thing>, the smallest unlock is <one precise ask>.
> If that is not possible, the workaround is <the fallback lane>."

Never: "access denied", "cannot proceed", "insufficient permissions" as the
headline. Those words may appear in the evidence detail, not as the answer.

## The fallback matrix

| Situation | What still works | The smallest unlock (tell the user exactly this) | Workaround if the unlock is not possible |
| --- | --- | --- | --- |
| No topology source configured at all | Guided capture: an operator-asserted map (service names, calls, entry points) — still the canonical names every audit uses | Add ANY one source block to the config (`/scoutflo:connect` detects existing CLI logins and offers them) | The zero-access discovery pack: their team runs one read-only script, reviews the output, hands it back |
| Cloud identity gate fails (wrong/expired login) | Every other configured source keeps working; the failed cloud is skipped with its name and the fix stated | Re-auth that one CLI (`aws sso login` / `az login` / `gcloud auth login`) or correct the config block | Map without that cloud now; re-run adds it later (carry-forward means nothing is re-asked) |
| Config reads denied (task defs / app settings / function config) | The access-tier gate detects this and runs the permitted + reachable + resource-side lanes; the map states "service configuration not readable at this access level" | The scoped read policy from the access checklist (a named document their security team can approve) — or, on Azure, the one-action elevated role, strictly opt-in | IaC-in-repo (their manifests/compose files declare the same wiring with placeholder values) + network flow logs + guided confirmation for the remainder |
| IAM / role / permission reads denied | Declared + reachable + observed lanes still run; permitted-lane corroboration is simply absent and confidence tiers say so | `iam:List*/Get*` (AWS) / Reader on the subscription (Azure) / `cloudasset.assets.searchAllIamPolicies` (GCP) | Trusted-source/firewall reads often survive when IAM reads do not; otherwise the review tier asks the user to confirm the weaker candidates |
| Network describes denied (security groups / private endpoints / peerings) | Declared + permitted lanes still run; edges lose the reachability corroboration and keep their honest lower tier | `ec2:DescribeSecurityGroups` (AWS) / Reader (Azure) / `compute.networks.list` (GCP) | Flow logs (if enabled) prove reachability better than rules do; else ship the declared-tier map |
| Flow logs absent or not readable | Everything else — flow logs are a bonus observed lane, never a dependency | Enable VPC/VNet flow logs on the subnets that matter + log-read access (they may already exist for security teams) | The APM overlay observes the same connections from the application side |
| No APM configured | All cloud lanes (declared/permitted/reachable + cloud observed probes) | Connect any one tracing/APM source the estate already has (New Relic key, or the metrics store where Tempo service-graphs land) | Cloud-side observed probes (App Signals, X-Ray, RDS PI on AWS) where enabled; else declared-tier confidence is stated honestly |
| One catalog family 403s (e.g. Redis list denied, SQL list fine) | Every other family; the map header names the blind family explicitly | The single list/describe action for that family | The family's resources can still enter the map via APM observation or guided capture, tagged accordingly |
| CLI/extension missing on the machine (doctl, az extension, crane) | Every lane not needing that binary; the gap is named in the header | Install the named binary (doctor names it exactly) | API-direct fallbacks exist where documented (e.g. the DigitalOcean VPC-members read uses the API because doctl lacks the command) |
| Zero access of any kind granted | A conversation is still a map: guided capture produces an asserted map with honest labels | Any single read-only credential from the checklist | The discovery pack — their team runs it inside their boundary; its output imports like live-lane data with its provenance recorded |

## Two rules that keep this honest

1. **A denial is recorded as evidence, not retried around.** No profile
   roulette, no credential guessing, no "try the default". The tier the run
   detected IS the answer, and re-runs upgrade automatically when access
   improves (nothing already confirmed is ever re-asked).
2. **User-supplied answers are labeled as theirs.** Whatever arrives through
   guided capture or the discovery pack is marked as asserted by them — and
   the platform upgrades it to discovered evidence automatically when a later
   run can finally see for itself.

## Where this is enforced

The access gates in each cloud cookbook fail closed with the exact fallback
message; the scope checkpoint announces which lanes will run BEFORE spending
effort; the map header states the access posture verbatim; and the review
session presents gaps as questions with their unlock, never as apologies.
