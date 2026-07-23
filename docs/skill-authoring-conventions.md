# Skill Authoring Conventions

Rules for every skill shipped in the Scoutflo AI Readiness. If a rule here conflicts with something you saw in another skill, this document wins; fix the other skill.

## Voice

You are writing for the engineer who runs the skill on their own infrastructure. Address them directly: "you", "your cluster", "your team". The report they generate is for their own colleagues.

Never write in consultant voice. Banned framings: "the customer", "the client", "engagement", "handover", "handoff", "sprint", "timeline", "access received", "Scoutflo recommends". If a sentence would only make sense coming from an outside consultant, rewrite it so it makes sense coming from the reader's own teammate.

Prose style: tight sentences, active voice, no em dashes. Every instruction should be executable or checkable; delete sentences that are neither.

## The three lanes

Every skill belongs to exactly one lane, visible in its name.

**`audit-*` (read-only, doctor-gated).** Audits observe and score. They run read-only operations only: GET, list, describe, query. No test notifications, no silences, no annotations, no state creation of any kind, however small. They start with the doctor gate, end by writing `findings.json` and `report.md` per the [report standard](../report-standard/README.md), and use the read-only credential tier.

**`setup-*` (mutating, confirmation-gated).** Setup skills fix findings. They take finding IDs from an audit run as input and follow this loop for every change, no exceptions:

1. **Announce**: show the exact change before touching anything: the API call, manifest, or config diff, with real values filled in.
2. **Confirm**: wait for the user to explicitly approve in the conversation. One approval may cover a batch only when every change in the batch was shown first. Never treat silence, a prior approval, or "fix everything" from three steps ago as consent for a new change.
3. **Execute**: apply exactly what was announced. If reality forces a different change, stop and re-announce.
4. **Verify**: re-fetch each modified object and assert the outcome with a machine-checkable command (see [Machine-checkable verification](#machine-checkable-verification)): a `jq -e` test on the re-fetched object, or a captured HTTP code compared against its stated expectation. A write is unverified until a read command proves it.
5. **Record**: append to a change record: what changed, the verification evidence, and anything still pending with a named owner, so your team can pick up where the run stopped.

Setup skills use the elevated credential tier, declare it in their doctor requirements, and end by recommending a fresh run of the corresponding audit skill.

**`guide-*` (advisory).** Guides explain, compare, and plan. They need no credentials and must not ask for any, run no mutating commands, and skip the doctor gate. If a guide finds itself wanting to query a live system, the content belongs in an audit skill.

## The live-safety gate

Before the first real check, every audit and setup skill verifies what it is pointed at:

- Print the resolved identity and target: the current kube context compared against `kubernetes.context` from the config, the cloud identity from the provider's whoami call with an explicit profile, the API identity from the service's health or self endpoint.
- If the resolved identity or context differs from what the config names, stop and report the mismatch. Never proceed on "probably the right cluster".
- Every command names its target explicitly: `kubectl --context "${KUBE_CONTEXT}"`, cloud CLIs with explicit profile, region, and project flags. Never rely on ambient defaults; the user's shell may point somewhere you did not expect.
- Classify every command as read-only or mutating before writing it into a skill. Classify by effect, not HTTP verb: some query APIs are POST and still read-only; some GET-shaped endpoints trigger work. Audit skills may contain read-only commands only.

## Config access

All configuration comes from `~/.scoutflo/toolkit.yaml` (see [the template](../templates/toolkit.yaml.example)). Hosts, orgs, and names live there in plain text. Secrets never do: every `*_env` key names an environment variable that holds the secret.

The pattern every skill follows:

```bash
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
# grafana.token_env names the variable; the secret stays in the environment.

# Presence check only. Never print, log, or echo the value.
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/health"
```

Rules:

- Resolve `*_env` names to variables; check presence, never value.
- Never echo, log, or write a secret anywhere: not in terminal output, not in reports, not in evidence, not in error messages.
- Never put a secret in a URL or query string; secrets travel in headers.
- If a required key or variable is missing, name it, point at `/scoutflo:connect`, and stop.

## The doctor gate

Every `audit-*` and `setup-*` skill begins by running the doctor checks for the integrations it needs, before any real work:

1. `~/.scoutflo/toolkit.yaml` exists and parses.
2. The config keys this skill requires are present.
3. Every required `*_env` variable is set (presence only).
4. Required binaries are installed (`curl`, `jq` always; `kubectl`, others as needed).
5. One cheap live call per required integration succeeds (a health or identity endpoint).

A failed check stops the skill with the exact failure and the fix, which is usually `/scoutflo:connect`. Never proceed past a failed doctor check, and never downgrade a doctor failure into a finding. Each skill lists its doctor requirements in a table: integration, config keys, env var, minimum scope, read-only or elevated.

## Estate sizing and proportionality

Ceremony must match estate size, in both directions. Every audit begins with an estate-sizing pre-check: count the objects the audit will judge (services, dashboards, alert rules, projects) with cheap list calls before any deep check runs. From the counts, the skill selects one of three paths and declares its choice in the terminal output:

- **Small**: a single pass over everything. No worklist, no batching.
- **Medium**: per-category passes, still completed in one run.
- **Large**: bounded batches of `BATCH_SIZE` objects worked against a durable worklist file under the run's date directory. The worklist records what is done and what remains, so an interrupted run resumes instead of restarting, and the report is assembled incrementally as batches complete.

Rules:

- The skill states its path thresholds as named variables with defaults (`SMALL_MAX_SERVICES="10"  # example, tune to your environment`) per the thresholds rule below, and prints which path it chose and the counts that drove the choice.
- Never run heavyweight ceremony on a tiny scope. Three services do not need a worklist file; an audit that spends longer on bookkeeping than on checks has failed proportionality.
- Never silently truncate a large estate. If the run judged a subset, the report names what was skipped and the coverage denominators reflect it.

## Large-path worklists: run-ID keying, resume, and locking

Skills on the large path (see [Estate sizing and proportionality](#estate-sizing-and-proportionality) above) keep a durable worklist file so an interrupted run resumes instead of restarting. Two rules apply to every such worklist, on top of the estate-sizing rules above.

**Key the run directory by run ID, not calendar date.** A directory named `./scoutflo-audits/<target>/<YYYY-MM-DD>/` breaks the moment a run starts at 23:58 UTC and is still batching at 00:02 UTC: the date changes mid-run, and the next batch either writes into a fresh, empty directory (silently abandoning everything already pulled) or the skill has to special-case "which date directory is mine". A run ID does not have this problem, because it is fixed once, at the start of the run, and never recomputed:

- Generate the run ID the first time the run creates its directory: a UTC timestamp with second precision, safe for a path component.
- Every command block in the run re-derives `RUN_DIR` from the same run ID (per the stateless-block rule above), not by recomputing "today's date".

```bash
set -eu
TARGET="lgtm"   # example; the audit's target slug
AUDIT_ROOT="./scoutflo-audits/${TARGET}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}"
echo "run: ${RUN_ID}"
echo "${RUN_ID}" > "${RUN_DIR}/run-id"   # so a later block, or a human, can confirm which run this directory belongs to
```

**Before creating a new run directory, look for one to resume.** A skill that always starts fresh throws away a run that was interrupted five minutes ago. At skill start, before minting a new `RUN_ID`, scan existing run directories under the target's audit tree for one whose worklist still has pending rows, and offer to resume it instead of starting over:

```bash
set -eu
TARGET="lgtm"   # example; the audit's target slug
AUDIT_ROOT="./scoutflo-audits/${TARGET}"

resumable=""
if [ -d "${AUDIT_ROOT}/runs" ]; then
  for d in "${AUDIT_ROOT}/runs"/*/; do
    [ -f "${d}worklist.tsv" ] || continue
    pending=$(awk -F'\t' '$2 == "pending"' "${d}worklist.tsv" | wc -l | tr -d ' ')
    [ "${pending}" -gt 0 ] || continue
    resumable="${d}"
    echo "resumable run found: ${d} (pending=${pending})"
  done
fi

if [ -n "${resumable}" ]; then
  echo "resume ${resumable} instead of starting a new run? offer this to the user before proceeding"
else
  echo "no resumable run found; safe to start a new one"
fi
```

❌ Started a fresh run directory every invocation without checking for a pending worklist, so a run interrupted at namespace 40 of 200 restarts from namespace 1 on the next invocation.
✅ Scanned `${AUDIT_ROOT}/runs/*/worklist.tsv` first, found one with 160 rows still `pending`, and resumed it instead of minting a new `RUN_ID`.

**Lock the worklist before claiming a batch.** Two invocations of the same large-path skill running at once (a human retry while an earlier session is still working, or two agents pointed at the same estate) will otherwise race on the same worklist file and double-claim or corrupt rows. Before claiming a batch, write a lock file next to the worklist; check for an existing one first, and treat a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size and expected run length) as abandoned and safe to reclaim.

```bash
set -eu
RUN_DIR="./scoutflo-audits/lgtm/runs/20260717T140500Z"   # example; the resolved run directory
LOCK="${RUN_DIR}/worklist.lock"
LOCK_STALE_MINUTES="30"   # example, tune to your batch size and expected run length

now_epoch=$(date -u +%s)
if [ -f "${LOCK}" ]; then
  lock_pid=$(awk -F'\t' 'NR==1{print $1}' "${LOCK}")
  lock_epoch=$(awk -F'\t' 'NR==1{print $2}' "${LOCK}")
  age_minutes=$(( (now_epoch - lock_epoch) / 60 ))
  if [ "${age_minutes}" -lt "${LOCK_STALE_MINUTES}" ]; then
    echo "worklist locked by pid ${lock_pid}, age ${age_minutes}m; stop, do not claim a batch"
    exit 1
  fi
  echo "existing lock is ${age_minutes}m old (>= ${LOCK_STALE_MINUTES}m); treating as abandoned and reclaiming"
fi

printf '%s\t%s\n' "$$" "${now_epoch}" > "${LOCK}"
echo "lock acquired: pid=$$ at ${now_epoch}"
# ... claim and process the batch here ...
rm -f "${LOCK}"   # release once the batch (not the whole run) completes
```

Rules:

- The lock covers one batch claim, not the whole run: acquire it right before reading pending rows, release it right after marking them done (or failed), so another process can claim the next batch.
- A lock file holds exactly two fields, tab-separated: the PID that holds it, and its UTC epoch start timestamp. Nothing else; the lock is not a place for run state.
- Reclaiming a stale lock is a normal, expected path, not an error: processes die, laptops sleep, sessions get killed. State it plainly in terminal output and move on.

## Findings and reports

Every audit skill conforms to the [report standard](../report-standard/README.md) in full: `findings.json` per the [schema](../report-standard/findings-schema.md), `report.md` per the [template](../report-standard/report-template.md), severity, status, scoring, and the end-to-end gate per [severity-and-scoring.md](../report-standard/severity-and-scoring.md).

The parts authors get wrong most often:

- Register a finding-ID prefix and keep a stable check catalog. IDs never change between runs.
- Evidence quotes real command output. If the skill cannot show the command and its output, the check does not exist.
- No end-to-end claim below the gate. Write "good base coverage" instead.
- Blocked categories are excluded and stated, never silently dropped or scored as if checked.
- Past the doctor and live-safety gates, the run always ends in a written report, whatever state the estate is in — mid-run failures become `blocked` checks or excluded categories, never an abort (severity-and-scoring.md rule 6).
- History has two artifacts with two jobs: finding-level matching and the delta read the most recent two `findings.json` files; the score trend renders from `history.jsonl`, which every run appends to. Never match findings against the ledger.

### Canonical vs derived artifacts

`findings.json` is canonical. `report.md`, the Slack brief, `history.jsonl`, and any export views are derived and regenerable. Skills never hand-edit a derived artifact to fix its content; they fix the findings (or the checks) and regenerate. The one exception is the user-owned sections explicitly marked as carried forward (topology watchpoints, exemptions.yaml), which no skill may overwrite.

## Paired examples for judgment rules

Every judgment rule a skill states carries one wrong/right example pair showing the rule applied: scoring calls, evidence quality, severity picks, naming. Mark the pair ❌ and ✅:

- ❌ `Scored alert routing 100: forty rules exist.`
- ✅ `Scored alert routing 50: rules are present and valid, but no receiver has proven delivery, so credit stops at partial.`

A rule without a pair reads as obvious until two runs score the same evidence differently. If you cannot write a wrong example someone would plausibly produce, the rule is not carrying weight; delete it.

## Slack brief

One message per run, derived exactly as [report-template.md](../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, report path. Titles only, never evidence values. A combined `audit-all` run sends one message total. A failed send is noted and never fails the run.

## topology.md

`./scoutflo-audits/topology.md` (written by `/scoutflo:map-topology`) is the shared service map. Rules:

- If it exists, load it. Use its service list as the critical-service list and its names as the canonical service names in findings, the coverage matrix, and `affected` arrays.
- Name affected services in findings. "Three services lack log coverage" is not a finding; "checkout, payments, and search lack log coverage" is.
- If it does not exist, discover services live, note in the report that the list was inferred, and suggest running `/scoutflo:map-topology`.
- Audit skills may propose updates to topology.md when live discovery contradicts it, but only the mapping skill and the user edit it.

## Thresholds: "tune this" framing

Any numeric threshold, retention period, replica count, sampling rate, or sizing figure in a skill is an example, not a prescription. Two obligations:

1. Declare it as a named variable at the top of the command block with its default: `ERROR_RATE_THRESHOLD="0.05"  # example, tune to your environment`.
2. Frame it in prose as a starting point: "alert when the error rate stays above `ERROR_RATE_THRESHOLD` (example value, tune to your traffic patterns)".

Never present one environment's numbers as universal truth. If you cannot explain why a default is a reasonable starting point for most environments, do not ship it as the default.

## Command style

POSIX-first, copy-pasteable, verified:

- Baseline tools are `bash`, `curl`, `jq`. Anything beyond (`kubectl`, `helm`, a vendor CLI) is a stated prerequisite and a doctor check.
- Every command block declares its placeholder variables at the top, each with a comment naming the `toolkit.yaml` key or the source it comes from. Below the declarations, the block runs as pasted: no pseudo-code, no angle-bracket placeholders inside command bodies.
- `curl` uses `-fsS` and `--max-time`; quote every expansion; parse JSON with `jq`, never with grep.
- Never pass a config-derived value through `eval`, anywhere, for any reason. Resolve indirection with `printenv "$var"` or direct expansion; a config file must not be able to execute code.
- Avoid GNU-only flags; the block must run on macOS and Linux. When there is no portable form, show both and label them.
- State the expected output after every check: what a healthy response looks like, and what the common failure shapes mean.
- After every mutating command, the very next command is the read that verifies it.
- Multi-line scripts start with `set -eu`.

## Stateless command blocks

Every command block runs correctly in a brand-new shell with no prior block executed. Skills are entered mid-run through anchors, blocks get copied out of order, and sessions restart; a block that depends on an earlier block fails in ways the reader cannot see.

- No helper functions defined in one block and called from another.
- Never write "reuse the variables from the previous block". Each block re-declares its inputs at the top, with the same source comments the config-access pattern requires.
- A block that genuinely needs a shared prelude is not a block; make it a script under the skill's `scripts/` directory and have blocks invoke the script.

## Machine-checkable verification

Every verify step is a command with an asserted outcome, never an instruction to look. Two accepted shapes:

```bash
# Shape 1: assert on the object. jq -e exits nonzero when the assertion fails.
GRAFANA_URL="https://grafana.example.com"   # grafana.url
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/contact-points" \
  | jq -e '.[] | select(.name == "oncall-webhook") | .type == "webhook"'
# Expect: exit 0, prints "true"

# Shape 2: assert on the status code. -f is dropped on purpose: the code is the observation.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/health")
echo "health: ${code}"
# Expect: 200
```

"Confirm the field now holds the value" as prose, with no command that fails when it does not, is a defect. When an outcome truly cannot be asserted by a command, say so in the skill, state exactly what a human must inspect, and treat that as a documented exception, never the default.

## Degrees of freedom

Mark every step as fixed or judgment. The two failure modes this prevents: an agent "improving" a fragile command, and an agent executing a heuristic as if it were a script.

- **Fixed steps** (mutations, live-safety checks, verification assertions, anything fragile): exact commands, stated as "run as written, do not modify flags". If the environment forces a deviation, the step says to stop and re-announce, never to adapt silently.
- **Judgment steps** (triage, prioritization, interpreting output, choosing what to check next): heuristics and the factors to weigh, without fake precision. Say what evidence would change the call.

A skill that marks neither invites both failure modes at once.

## Skill structure

Follow the standard Claude Code skill layout:

```
skills/
  <name>/
    SKILL.md            # the workflow: phases, commands, gates, outputs
    references/         # only when needed
      <topic>.md        # lookup tables, per-flavor API paths, payload cookbooks
    scripts/            # only when needed
      <task>.sh         # small POSIX helpers replacing blocks that would need shared state
```

- `SKILL.md` holds the workflow and should stay under roughly 350 lines. When it would exceed that, move lookup material (API path tables per backend flavor, payload examples, check catalogs) into `references/*.md` and link to it. Workflow stays in `SKILL.md`; references hold what you look up mid-run.
- `scripts/` holds small helper scripts bundled with the skill, born from the stateless-block rule: a sequence that needs shared functions or state becomes one script invoked by one block. Scripts are POSIX shell, non-interactive, use no `eval`, and stay small; anything that reads like an application belongs outside this repo.
- Skill names are the public API: `<lane>-<target>`, lowercase kebab-case. Names are frozen at first release.
- Every skill ends with a Common Failure Modes table (see below).

## Entry routing

Findings point readers into setup skills through remediation anchors (`setup-lgtm#fix-default-receiver`). Any skill entered that way opens with a routing table, immediately after its intro, mapping finding IDs to section anchors:

```markdown
| Finding ID | Fix section |
| --- | --- |
| LGTM-014 | [Fix the default receiver](#fix-default-receiver) |
| LGTM-031 | [Standardize service labels](#standardize-service-labels) |
```

The reader arrives holding a finding ID; the table takes them to the fix without scanning the whole skill. Two integrity rules: every anchor in the table resolves to a heading in the same file, and every remediation pointer the sibling audit can emit appears as a row.

## Frontmatter

Two fields for audit and guide skills. Setup skills carry exactly one more:

```yaml
---
name: setup-grafana
description: Guided hardening of Grafana datasources, dashboards, contact points, notification policies, and alert rules from audit-grafana findings; announces each change, waits for confirmation, applies, then verifies live. Use when the user asks to fix a GRAF-NNN finding, wire or repair contact points, clean up broken panels or datasources, or harden Grafana alerting. Do not use for backend stores like Loki or Mimir (use setup-lgtm) or for read-only assessment (use audit-grafana).
disable-model-invocation: true
---
```

- `name` equals the skill folder name.
- `description` follows the description standard below. It sits in every user's context window on every conversation, so every character must earn its place as a trigger or a boundary.
- `disable-model-invocation: true` is mandatory on every mutating (`setup-*`) skill and appears on no other lane. Mutation skills fire only when the user explicitly invokes them; the model never routes into one on its own.

## Description style

The description is the router's only signal. One formula, written in third person, up to roughly 500 characters:

1. **What it does, key use case first.** One sentence naming the lane behavior, the objects it touches, and what it produces. This is the part a human reads to decide whether to trust the skill.
2. **Positive triggers.** "Use when the user mentions ..." followed by the literal nouns, verbs, product names, and error strings users actually type. Write the words they say, not the words the skill prefers. Literal phrases, not an unstructured keyword dump: twelve product names with no action attached tell the router nothing about when not to fire.
3. **Negative triggers.** "Do not use for X; use <sibling> instead" for every sibling this skill is regularly confused with. Boundaries are what keep three observability skills from firing on the same sentence.

Never enumerate the skill's phase sequence in the description. Phases belong in the body; a description that narrates "first it does A, then B, then C" spends its whole budget on words that never trigger a route.

Three pairs, written to the formula:

**audit-lgtm**

- Good: `Read-only scored audit of LGTM and VictoriaMetrics observability stacks; writes findings.json and report.md. Use when the user mentions auditing or scoring Loki, Tempo, Mimir, VictoriaMetrics, VictoriaLogs, vmalert, or Alertmanager, or asks whether metrics, logs, traces, or alerting are healthy or production-ready. Do not use for the Grafana application layer (use audit-grafana), for proving alerts reach a human (use audit-alert-routing), or to change anything (use setup-lgtm).`
- Bad: `Read-only scored audit of LGTM and VictoriaMetrics observability stacks. Verifies metrics, logs, traces, alert routing, and dashboards per service, then writes findings.json and report.md.`
- Why: the bad one is accurate but routes poorly. It has no "use when" phrases a user would type and no boundary against audit-grafana or audit-alert-routing, so the router guesses between three siblings that all mention alerting.

**setup-grafana**

- Good: `Guided hardening of Grafana datasources, dashboards, contact points, notification policies, and alert rules from audit-grafana findings; announces each change, waits for confirmation, applies, then verifies live. Use when the user asks to fix a GRAF-NNN finding, wire or repair contact points, clean up broken panels or datasources, or harden Grafana alerting. Do not use for backend stores like Loki or Mimir (use setup-lgtm) or for read-only assessment (use audit-grafana).`
- Bad: `Helps with Grafana.`
- Why: the bad one has no action, no trigger words, no lane, no outputs, no boundaries; the router cannot tell when to fire it and the user cannot tell what it will do to their Grafana.

**audit-alert-routing**

- Good: `Read-only proof that the paging path works and is not drowning in noise: follows each alert rule through Alertmanager routes to a live receiver, scores delivery gaps, and scores alert-hygiene gaps (flapping, permanently-firing rules, missing debounce, missing grouping or inhibition) as findings. Use when the user asks whether alerts actually reach a human, or mentions silent alerts, missed pages, dead receivers, alert noise, alert fatigue, or flapping alerts. Do not use to change routing (use setup-lgtm or setup-grafana) or for a full stack audit (use audit-lgtm).`
- Bad: `Assess the customer's alerting posture and prepare a remediation proposal with timeline and access requirements.`
- Why: the bad one is consultant voice aimed at a third party, promises deliverables this toolkit does not produce, and contains no words a self-service user would say.

## Common Failure Modes table

Every `SKILL.md` ends with a two-column table of real failure classes and their prevention:

```markdown
## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Loki syntax used against a different log backend | Detect the deployed backend and its query language before judging query failures |
| Alerts exist but go nowhere | Prove receiver delivery; inspect notification logs, not just rule lists |
```

Entries come from mistakes actually made running this kind of work, generalized so they apply to any environment. If you cannot name the prevention as a concrete action, the row is not ready.

## Forbidden content

This repository is public. Skills are written from scratch for it: extract the lesson and rewrite. Never paste internal material and then redact it; scrubbing misses things, rewriting cannot leak what it never contained.

None of the following may appear anywhere in the repo, including examples, comments, test fixtures, and commit messages:

- Names of any real company, customer, or customer environment.
- Cloud account identifiers: AWS account IDs, GCP project numbers or IDs, subscription IDs, org IDs from real accounts.
- Machine-specific paths: home directories, user names in paths, drive-letter paths.
- Personal names and email addresses.
- Real hostnames, domains, or URLs from any internal or customer environment. Use `example.com` forms.
- Names of internal systems, repositories, branches, environments, or tooling that do not ship in this toolkit.
- Kubeconfig context names, cluster names, or namespaces from real environments.
- Org slugs, project slugs, dashboard UIDs, channel IDs, or integration IDs from real accounts.
- Credential material of any kind: token values, token prefixes, DSNs, webhook URLs, keys. Refer to secrets only by `*_env` variable names.
- Boilerplate blocks copied from internal skill packs, and cross-references to skills that do not ship in this plugin. Every cross-reference must resolve to a skill or doc in this repo.
- One environment's operational numbers presented as defaults. Regions, thresholds, fleet sizes, and retention figures from any real setup must become placeholders or be framed as "example, tune to your environment" (see the thresholds rule above).

CI runs a secrets and identifier scan plus `claude plugin validate --strict` on every pull request; a hit blocks merge. Treat the scanner as a backstop, not the gate: the gate is that you never typed it in the first place.
