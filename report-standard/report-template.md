# report.md Template

`report.md` is the human-readable half of an audit run. It is generated from the same data as `findings.json` and must never disagree with it. Sections appear in the order below; empty sections state why they are empty rather than disappearing.

**Output conformance (enforced).** Every generated `report.md` must pass [`check-report.sh`](check-report.sh), which validates this skeleton: the header table, the canonical `**Score: <n>/100**` line for assessed runs (or `**Readiness: unassessed**` for a fully blocked v2 run), and the required section spine (**At a glance**, Executive summary, Scorecard, Findings, Next safe actions, Evidence appendix) in order. It also warns when the standalone `report.html` dashboard is missing next to `report.md`.

**Visuals are generated, never hand-written.** [`render-report-viz.sh`](render-report-viz.sh) renders the At-a-glance block, the scorecard bars, the findings-by-purpose view, an optional Mermaid blast-radius graph, and the standalone `report.html` dashboard — all computed from the canonical `findings.json` (+ `history.jsonl` for the trend, `topology-export.json` for the graph), so a visual can never drift from the numbers. In Phase 8, after `findings.json` is written and `check-findings.sh` passes, each audit runs the generator to write `report.html` and to produce the At-a-glance and findings-by-purpose blocks it pastes into `report.md`, then runs `check-report.sh`. Each audit skill runs it on its own `report.md` in its final phase before declaring the run done, so rendered output cannot silently drift from this template. Run it directly with `sh report-standard/check-report.sh path/to/report.md`; it exits non-zero and lists each violation when a report drifts. A report that does not match this template is a bug, not a style choice.

## Skeleton

~~~markdown
# <Audit name>: <target>

| | |
| --- | --- |
| Target | <target slug> |
| Date | <YYYY-MM-DD> (UTC) |
| Toolkit version | <x.y.z> |
| Skill | <skill name> |
| Critical services | <n> (from topology.md | inferred live) |

## At a glance

<Rendered from findings.json by `render-report-viz.sh`, never hand-written, so
the visuals can never disagree with the numbers. Paste the output of
`sh report-standard/render-report-viz.sh at-a-glance <findings.json> <history.jsonl>`
verbatim: the **Score: n/100** bar, the trend sparkline, checks-passed, the
severity histogram table, and the "Start here →" top lever (highest
points_recoverable). Optionally follow it with the Mermaid blast-radius graph
from `render-report-viz.sh mermaid-topo <topology-export.json> <service>` when a
topology export exists. The same generator writes the standalone `report.html`
dashboard (score donut, severity bars, sortable scorecard + findings) next to
report.md.>

## Executive summary

<3 to 6 sentences: overall score and what it means, the single most
urgent finding, whether the end-to-end label applies and if not what
blocks it, what moved since the last run. Plain language, no jargon
the reader's manager could not follow.>

**Score: <n>/100** (gate for end-to-end: 85) | <X> of <Y> assessed checks passed; <severity counts>
**Assessment coverage: <a>/<applicable> (<p>%).** <s> scored; <b> applicable checks blocked; <x> suppressed; <n> not in scope.
**Gap to target: <n> points.** Biggest levers: <PREFIX-NNN> (+<p>), <PREFIX-NNN> (+<p>), <PREFIX-NNN> (+<p>).
<If categories were excluded: "Scored across <k> of <m> categories;
<category> excluded (<reason>).">
<If every applicable check was blocked: replace the score and gap lines with
"**Readiness: unassessed** 0/<applicable> applicable checks assessed" and list the
evidence-unlock actions. Never render 0/100 or 100/100.>

## Scorecard

| Category | Weight | Score | Maturity | Passed / scored | Blocked | Suppressed | Notes |
| --- | ---: | ---: | --- | ---: | ---: | ---: | --- |
| <category> | <w> | <s>/100 | reactive | <passed>/<scored> | <blocked> | <suppressed> | <one-line note> |
| <category> | <w> | <s>/100 | systematic | <passed>/<scored> | <blocked> | <suppressed> | <one-line note> |
| <excluded category> | <w> | excluded | - | - | <blocked> | <suppressed> | <reason> |

## Findings by purpose

<Paste the output of
`sh report-standard/render-report-viz.sh lanes <findings.json>` verbatim.
This provides two reader paths over the same canonical findings: General audit
for reliability, security, capacity, backup, alerting, and operational hygiene;
AI SRE readiness for telemetry quality, service identity, topology, ownership,
change context, routing evidence, and safe RCA/automation. A finding can appear
in both lists, but its detailed evidence is rendered only once below. This split
does not create a second score or change severity.>

## Findings

<Ordered by severity, critical first, then by points_recoverable
descending within a severity. Each finding is written for a reader who has
never seen this tool: a plain-language heading, then What / Where / Why /
How, with the stable check ID demoted to a small reference line. Capped at
the top REPORT_MAX_FINDINGS (25; example, tune to your estate size). When
findings.json holds more, render the cap then one line: "12 more findings
in findings.json, ordered by points_recoverable." findings.json stays the
complete, canonical list; raw command output stays in the Evidence
appendix, keyed by the same ID.>

### <emoji> <Severity> · <plain-English one-line heading>

**What's wrong:** <one to three plain sentences naming the actual problem —
no jargon a manager could not follow. From the finding `title` expanded.>

**Where:** <the exact location — the resource, service, namespace, route,
alarm, receiver, or host, from `affected`. Never just "the cluster" — name
the thing. **When `affected` names more than one object, you MUST render it
as a table (one row per object), never a comma-separated sentence or an
inline bullet list.** A multi-item "Where" is always a table here — that is
not a stylistic choice, it is the required format, so the report stays
scannable and every model (not only the strongest) produces it identically.
For a single object, one inline line is fine: `**Where:** <the one object>`.>

<Multi-object form — REQUIRED whenever `affected` has 2 or more entries.
Lead with the count, then the table. Use a second column only when every
entry cleanly splits the same way (e.g. namespace + name); otherwise keep the
single `Affected` column and put the full identifier in it.>

**Where:** <N> objects affected:

| # | Affected |
| ---: | --- |
| 1 | <namespace/object, resource id, receiver, alarm, or host> |
| 2 | <...> |

**Why it matters:** <the concrete consequence if left unfixed (from
`impact`).>

**How to fix:** <1 to 3 numbered steps, each one concrete imperative naming
the exact object (the receiver, rule, edge, field, resource) and the exact
change — from `recommendation`, with `/scoutflo:<setup-skill>` (<anchor>)
cited on the step it automates. Never a bare "run the setup skill" with no
object named.>
**Done when:** <one observable condition a teammate can verify without
context — a command output, a UI state, a re-run column reading pass.>

<sub>ref: <PREFIX-NNN> · <category> · <lifecycle>, <status></sub>

<Repeat the block per finding. Severity emoji: critical 🔴, high 🟠,
medium 🟡, low 🔵, info ⚪. The `ref:` line is the only place the coded ID
appears in a finding — a human should never need it to understand the
finding; it exists for delta tracking, the Evidence appendix, and
exemptions.>

## Suppressed findings

| ID | Title | Reason | Approved by | Expires |
| --- | --- | --- | --- | --- |
| <PREFIX-NNN> | <title> | <reason from exemptions.yaml> | <who> | <date> |

<Empty state: "No exemptions configured." Malformed or expired entries
are called out here.>

## Coverage matrix

| Service | Ready | <signal columns per skill> | Alerts | View | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- |
| <service> | <n/n> | pass/partial/fail/blocked | ... | ... | Known/Unknown | <gap or -> |

## Scoutflo Topology Readiness

**<r> of <n> critical services are ready for automatic Scoutflo correlation.** <One sentence: what fixing
the blocking findings unlocks (platform source and correlation sync).>

| Service | Service identity | Workload mapping | Telemetry connections | Connection details | Tool identity | Match confidence | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| <service> | pass | pass | 2/3 declared | missing: <provider attr> | pass | 8/10 | partial |

<sub>Checks T1-T6 per [topology-readiness.md](topology-readiness.md); confidence scale is 0-10, actionable at 8/10 or higher.</sub>

**Sync-readiness action plan** <required whenever any service is below
ready; each row is ticket-ready per topology-readiness.md>

| # | Service | Blocked on | Do this | Done when |
| --- | --- | --- | --- | --- |
| 1 | <service> | <check name> | <one imperative naming the exact object and change, citing <PREFIX-NNN> when a finding exists> | <observable condition> |

<Column headers are the plain-English check names from
topology-readiness.md — never the raw T1-T6 codes, which appear only in
the legend line. Confidence renders as n/10, never a bare number.
Verdicts: ready / partial / not-ready. Missing or target-mismatched
topology-export.json: render the matching state from
topology-readiness.md ("When the export is missing or does not match the
audit target") with its one-line unlock — never a bare "unavailable",
never a guess. Blocking gaps reference finding IDs where one exists.>

## Inventory

<The complete current-state catalog of what the target has configured — the
"here is everything you have" list, parallel to Findings (the gaps). Generated
from `inventory.json` (`scoutflo-inventory/v1`, see
[inventory-schema.md](inventory-schema.md)) via
`render-report-viz.sh inventory <inventory.json>`; never hand-write it —
regenerate, the same rule as findings. One table per object kind
(name · covers · severity · routes to · enabled). A disabled or unrouted object
still appears — that it exists but is off or unwired is exactly the fact the
inventory surfaces. An empty estate renders an honest "no objects found" line,
paired with the empty/hidden-scope guardrail (genuinely empty vs. can't-see-it).
`/scoutflo:audit-all` renders the cross-stack `## Estate inventory (all stacks)`
rollup via `render-report-viz.sh inventory-rollup`. This is the AI Readiness
POC's alert/asset-inventory deliverable; it never enters the 0-100 score.>

## <Provider-specific parallel section, when the skill defines one>

<Optional. An audit skill may define its own named section here for a
signal that genuinely does not belong on the 0-100 reliability score
(see "Parallel non-scored sections" below) — for example audit-aws's
"Cost & Resource Optimization". Omit this heading entirely for a skill
that has no such section; it is not a mandatory part of the skeleton
the way Topology Readiness is.>

## Next safe actions

| # | Finding | Severity | Action |
| --- | --- | --- | --- |
| 1 | <PREFIX-NNN> | critical | Run `/scoutflo:<setup-skill>` (<anchor>): <one line on what it changes> |

<Ordered by severity, then by safety: verification-only steps before
mutating ones. Every row points at a finding ID and a remediation
pointer. No timelines, no phases, no effort estimates.>

## Delta since <previous run date>

Score: <prev> -> <current> (<+/-n>). <Per-category movement for
categories that moved.>

Trend (last <k> runs): <s1> -> <s2> -> <s3> -> <s4> -> <current>

- Fixed (<n>): <ID: title, ...>
- New (<n>): <ID: title, ...>
- Unchanged (<n>): <IDs; call out any whose affected list changed>

<First run: "First run, no delta." and the trend line is omitted.
Otherwise the trend renders the last five history.jsonl entries,
oldest first; fewer than five runs, render what exists.>

## Evidence appendix

### <PREFIX-NNN>: <title>

Check: <what was verified>

```
$ <command>
<observed output, trimmed, truncation marked>
```

<One evidence block per item, grouped under the finding ID.
Real output only. No secrets, ever. Same cap as the Findings table:
appendix entries stop at the top REPORT_MAX_FINDINGS (25; example,
tune to your estate size) findings by severity then points_recoverable,
followed by "12 more findings in findings.json, ordered by
points_recoverable." A finding that is capped out of the appendix
still gets its row in the Findings table (or its own "N more" line if
the table cap already dropped it); findings.json always has the full
evidence for every finding regardless of the report-level cap.>

---
Generated by [Scoutflo AI Readiness](https://scoutflo.com) for Claude Code.
~~~

## Section rules

- **Header**: target, date, and toolkit version are mandatory; they make any report file self-identifying when it gets copied around.
- **Executive summary** is written for a reader who will read nothing else. Lead with the verdict, not the methodology. The gap-to-target line follows the gap model in [severity-and-scoring.md](severity-and-scoring.md): gap in points, then the two or three open findings with the highest `points_recoverable` as the biggest levers.
- **Scorecard** mirrors `score.categories` and `score.excluded` exactly, including the maturity value per category (`reactive`, `proactive`, `systematic`; definitions in [severity-and-scoring.md](severity-and-scoring.md)). For v2, show `checks_passed/checks_total` as passed over the unsuppressed readiness denominator and show blocked and suppressed separately. Excluded rows stay visible with their reason; they do not vanish or render a second numeric row.
- **Scoring scope** is explicit on every v2 finding. Use `scoring_scope: readiness` when it explains a same-ID non-pass check. Use `scoring_scope: non-scored` only for an intentional parallel section, such as a cost opportunity, with no check row and zero recoverable readiness points.
- **Findings by purpose** is derived from each v2 finding's `report_lanes` with `render-report-viz.sh lanes`. It is a navigation and ownership split only. General audit covers foundational operational defects; AI SRE readiness includes only evidence-backed gaps that reduce telemetry correlation, incident context, RCA trust, or action safety. Do not invent a second score, change severity, or duplicate detailed evidence.
- **Every number carries its scale or denominator.** A score is `43/100`, a check count is `12/14`, a confidence is `8/10`, a coverage cell is `2/3`. A bare number with no total is a conformance bug anywhere in the report — the reader should never have to know the scale from memory.
- **Findings** are written for any reader, not just the person who ran the tool. Each renders as a plain-English heading plus **What's wrong / Where / Why it matters / How to fix / Done when**, in that order. "Where" always names the concrete location (resource, service, namespace, route, alarm, receiver, host), never a vague "the cluster" — and **when it names more than one object it is rendered as a table (one row per affected object), never a comma-separated sentence or inline list**; a multi-item "Where" being a table is a conformance requirement, not a preference, so the format is identical no matter which model writes the report. "How to fix" is 1 to 3 numbered concrete steps naming the exact object and change (the setup-skill pointer cited on the step it automates, never as the whole fix); "Done when" is one observable verification condition. A fix a reader cannot start executing, or verify finishing, without asking follow-up questions is a conformance bug. The coded check ID (`ALR-002`, `DO-050`, ...) is demoted to the small `ref:` line and is the only place it appears in a finding — it exists for delta tracking, the Evidence appendix, and exemptions, and a human should not need it to understand the finding. The full raw command output lives once, in the Evidence appendix, keyed by the same ID, so the finding stays readable. Lifecycle values follow the finding lifecycle table in [findings-schema.md](findings-schema.md). Findings and the appendix cap at `REPORT_MAX_FINDINGS` (25; example, tune to your estate size), ordered by severity then `points_recoverable` descending; the remainder is a single "N more findings in findings.json, ordered by points_recoverable" line. `findings.json` is never capped; the report cap only shortens what gets rendered.
- **Suppressed findings** lists findings silenced by a live exemption, with the reason, approver, and expiry from exemptions.yaml. Suppressed findings are excluded from the score and severity counts; the scorecard states the suppressed count.
- **Coverage matrix** uses the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`) and the service names from topology.md when present. Every cell and every findings-table area shows `passed/total` (e.g. `alert routing 12/14`).
- **Scoutflo Topology Readiness** follows [topology-readiness.md](topology-readiness.md): per critical service, are its identity, workload mapping, telemetry connections, connection details, tool identity, and match confidence sufficient for automatic correlation once findings are fixed. **This section must be written for a reader with zero prior context on Scoutflo's internals** — no internal terms ("edge", "sync-ready", `MONITORED_BY`, correlation attribute), no internal file names (`topology-export.json`, `topology.md`) in prose, and no assumption the reader knows what any of that means; a customer who pastes this section into their own AI assistant should get a grounded answer, not a hallucinated one built on undefined jargon. Table headers use the plain-English check names (T-codes only in the legend line); confidence renders as `n/10`; any service below ready triggers the ticket-ready readiness action plan table, written the same way — plain infrastructure terms, no internal data-model vocabulary. A missing or target-mismatched service map renders the matching state with its unlock path in plain language, never a bare "unavailable" and never a guess.
- **Parallel non-scored sections**: an audit skill may define its own named report section for a signal that does not belong on the 0-100 reliability score — mixing an unrelated axis into the score creates a perverse incentive (an idle standby database replica is "waste" by a cost lens and "correct" by a reliability lens; scoring both on one axis rewards the wrong fix). Scoutflo Topology Readiness is the first example of this pattern; `audit-aws`'s Cost & Resource Optimization section is the second. Findings in a parallel section use their own registered ID prefix (per [findings-schema.md](findings-schema.md)'s parallel non-scored sections rule), always carry `points_recoverable: 0`, and render under their own heading instead of in the Findings table — never folded into `score.categories` or `score.excluded`, since they were never scoring candidates to begin with.

- **Cost / savings sections lead with a totals line, then the table.** When a parallel section reports money (AWS/GCP/any cloud cost optimization), a bare per-row table buries the number the reader actually wants. Open the section with a one-line **savings summary** built only from the AWS/provider-native figures already on the findings — never a recomputed or invented number:

  > **Potential savings: ~$1,240/month (~$14,880/year)** across **9 opportunities** with a provider-sourced figure; **4 more** opportunities found with no dollar figure available (presence facts). Largest single lever: **$340/mo** — right-size `db-primary` (Over-provisioned).

  Rules for the summary line: sum only the `estimated_monthly_savings_usd` values that came verbatim from a provider recommendation API; multiply by 12 for the annual figure and label it clearly as an estimate ("~", "potential"); state the count of opportunities *with* a figure separately from the count *without* one (so the reader never reads "$1,240" as the whole story when 4 items have no number); name the single biggest lever. If **no** row has a provider-sourced figure, say so plainly ("N opportunities found; no provider-sourced dollar figures available — each is a presence fact to review") rather than printing `$0`, which would falsely imply nothing to save. Then render the per-row table below the summary. Every number carries its unit and period (`/mo`, `/year`), and no figure appears that was not copied from a provider API — the toolkit-wide "never invent a number" rule applies doubly to money, because it gets pasted into a budget conversation.

- **Every score and count reads as a plain-language sentence, not just a digit.** The executive summary already states the score; reinforce comprehension by pairing each headline number with what it means in one clause — `72/100 readiness across 87% assessment coverage`, `41/47 assessed checks passed; 6 applicable checks blocked`, `Topology readiness 4/6 services (2 need a provider attribute added)`. A number the reader has to interpret from memory is a missed chance to guide them. Never present a v2 readiness score without its assessment coverage when coverage is below 100%.

- **Lead the reader to the highest-value action.** The executive summary's "Biggest levers" line and the Next safe actions table already exist; make the single top action unmistakable — one bolded first line the reader can act on without reading the whole report, e.g. **"Start here: add a real default receiver (ALR-014) — recovers the most points and closes the biggest paging gap."** Guiding attention is as valuable as the data itself.
- **Next safe actions** is the bridge to the setup lane: finding ID to remediation pointer, ordered so the reader can start at row 1 without preparing anything else.
- **Delta** follows the rules in [README.md](README.md). Finding matching uses the previous run's findings.json; the trend line renders the last five entries of `history.jsonl` per the History ledger rules there, and never drives finding lifecycle.
- **Evidence appendix** obeys the evidence rules in [findings-schema.md](findings-schema.md): real output, errors as evidence, secrets never. Same `REPORT_MAX_FINDINGS` cap as the Findings table, same ordering, same "N more findings in findings.json" pointer for the rest.

## Slack brief derivation

When Slack delivery is configured, the skill derives one brief per run from the report. The brief contains, in order:

1. Skill and target, date.
2. Score with movement: `72/100 (+9)` only when the scoring model and check set match the baseline; otherwise `72/100 (score delta not comparable: check set changed)`, plus the end-to-end label state.
3. Severity counts: `1 critical, 2 high, 4 medium, 3 low`.
3a. Check totals and assessment coverage: `41/47 assessed checks passed; 47/53 applicable checks assessed (89%); 6 blocked`.
4. Top 3 to 5 finding titles, highest severity first, each with its ID.
5. Delta line: `3 fixed, 1 new, 6 unchanged` (or `first run`).
6. Topology readiness line: `Topology readiness: 4 of 6 critical services are ready for automatic Scoutflo correlation` (counts only, no service names required).
7. The local report path.

Hard rules:

- **Titles only, never evidence values.** No command output, no hostnames, no endpoints, no counts extracted from evidence. The webhook posts to a chat system you do not fully control; the brief must be safe to leak.
- One message per run. A combined run (`audit-all`) sends exactly one message covering all its audits, with one score line per target.
- The webhook comes from `slack.webhook_env` in `~/.scoutflo/toolkit.yaml`. If it is unset or the send fails, say so in the terminal output and continue. A failed brief never fails the audit.

## Run-completion message (what the skill says in chat when the run finishes)

After the artifacts are written and verified, every audit closes with a short, consistent chat message — not a bare "done". Its job is to give the headline and make it obvious how to open and share the report. Keep it to the shape below; it is guidance for the closing message, not another file.

1. **One-line headline:** target, score with movement, and the end-to-end label state. Example: `Grafana audit complete — 72/100 (+9), good base coverage (not end-to-end).`
2. **The two or three biggest levers**, by `points_recoverable` — the same top findings the executive summary leads with, as plain titles. Example: `Top fixes: add a real default receiver, route paging alerts to PagerDuty, set for: on the flapping CPU rule.`
3. **Where the report is — the resolved ABSOLUTE path**, so it is clickable/openable with no guessing. Print the real path the run used (resolve `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}` to an absolute path), e.g. `Report: $HOME/scoutflo-audits/grafana/2026-07-28/report.md` (with `$HOME` expanded to the actual path).
4. **How to open it**, with the command for the user's OS:

   ```bash
   # macOS
   open "<abs-path>/report.md"
   # Linux
   xdg-open "<abs-path>/report.md"
   # Windows (PowerShell)
   Invoke-Item "<abs-path>\report.md"
   ```

   Also mention it is plain Markdown, so it renders in any editor, VS Code preview, or by pasting into a Markdown viewer.
5. **How to share it (with the privacy caveat):** the full `report.md` names hosts, namespaces, and routes, so share it inside the team, not publicly. For a safe-to-post summary, point at the Slack brief (titles + scores only) — already sent if `slack.webhook_env` is configured, or offer to send it. Say plainly: *"the full report contains infrastructure detail; the Slack brief is the leak-safe version."*
6. **The obvious next step:** re-run after fixes to see the delta, or run another audit / `audit-all`. One line.

Hard rules for this message:
- Never print a secret, an evidence value, a token, or a raw finding body in the chat close — the headline, top titles, the path, and the open/share commands only. The detail lives in `report.md`.
- Always give the **absolute** report path, never a bare `./scoutflo-audits/...` the user then has to resolve against an unknown working directory.
- If the run was blocked at a gate (no `report.md` written), there is no completion message — the gate's stop-and-fix guidance stands instead.
