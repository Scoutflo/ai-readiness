# report.md Template

`report.md` is the human-readable half of an audit run. It is generated from the same data as `findings.json` and must never disagree with it. Sections appear in the order below; empty sections state why they are empty rather than disappearing.

**Output conformance (enforced).** Every generated `report.md` must pass [`check-report.sh`](check-report.sh), which validates this skeleton: the header table, the canonical `**Score: <n>/100**` line, and the required section spine (Executive summary, Scorecard, Findings, Next safe actions, Evidence appendix) in order. Each audit skill runs it on its own `report.md` in its final phase before declaring the run done, so rendered output cannot silently drift from this template. Run it directly with `sh report-standard/check-report.sh path/to/report.md`; it exits non-zero and lists each violation when a report drifts. A report that does not match this template is a bug, not a style choice.

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

## Executive summary

<3 to 6 sentences: overall score and what it means, the single most
urgent finding, whether the end-to-end label applies and if not what
blocks it, what moved since the last run. Plain language, no jargon
the reader's manager could not follow.>

**Score: <n>/100** (gate for end-to-end: 85) | <X> of <Y> checks passed; <severity counts>
**Gap to target: <n> points.** Biggest levers: <PREFIX-NNN> (+<p>), <PREFIX-NNN> (+<p>), <PREFIX-NNN> (+<p>).
<If categories were excluded: "Scored across <k> of <m> categories;
<category> excluded (<reason>).">

## Scorecard

| Category | Weight | Score | Maturity | Checks | Notes |
| --- | ---: | ---: | --- | ---: | --- |
| <category> | <w> | <s>/100 | reactive | <passed>/<total> | <one-line note> |
| <category> | <w> | <s>/100 | systematic | <passed>/<total> | <one-line note> |
| <excluded category> | <w> | excluded | - | - | <reason> |

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

**Where:** <the exact location: the resource, service, namespace, route,
alarm, receiver, or host, and which/how many objects are affected (from
`affected`). Never just "the cluster" — name the thing.>

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

**<r> of <n> critical services sync-ready.** <One sentence: what fixing
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
- **Scorecard** mirrors `score.categories` and `score.excluded` exactly, including the maturity value per category (`reactive`, `proactive`, `systematic`; definitions in [severity-and-scoring.md](severity-and-scoring.md)). Excluded rows stay visible with their reason and carry `-` for maturity and checks; they do not vanish.
- **Every number carries its scale or denominator.** A score is `43/100`, a check count is `12/14`, a confidence is `8/10`, a coverage cell is `2/3`. A bare number with no total is a conformance bug anywhere in the report — the reader should never have to know the scale from memory.
- **Findings** are written for any reader, not just the person who ran the tool. Each renders as a plain-English heading plus **What's wrong / Where / Why it matters / How to fix / Done when**, in that order. "Where" always names the concrete location (resource, service, namespace, route, alarm, receiver, host), never a vague "the cluster". "How to fix" is 1 to 3 numbered concrete steps naming the exact object and change (the setup-skill pointer cited on the step it automates, never as the whole fix); "Done when" is one observable verification condition. A fix a reader cannot start executing, or verify finishing, without asking follow-up questions is a conformance bug. The coded check ID (`ALR-002`, `DO-050`, ...) is demoted to the small `ref:` line and is the only place it appears in a finding — it exists for delta tracking, the Evidence appendix, and exemptions, and a human should not need it to understand the finding. The full raw command output lives once, in the Evidence appendix, keyed by the same ID, so the finding stays readable. Lifecycle values follow the finding lifecycle table in [findings-schema.md](findings-schema.md). Findings and the appendix cap at `REPORT_MAX_FINDINGS` (25; example, tune to your estate size), ordered by severity then `points_recoverable` descending; the remainder is a single "N more findings in findings.json, ordered by points_recoverable" line. `findings.json` is never capped; the report cap only shortens what gets rendered.
- **Suppressed findings** lists findings silenced by a live exemption, with the reason, approver, and expiry from exemptions.yaml. Suppressed findings are excluded from the score and severity counts; the scorecard states the suppressed count.
- **Coverage matrix** uses the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`) and the service names from topology.md when present. Every cell and every findings-table area shows `passed/total` (e.g. `alert routing 12/14`).
- **Scoutflo Topology Readiness** follows [topology-readiness.md](topology-readiness.md): per critical service, are its identity, workload mapping, telemetry connections, connection details, tool identity, and match confidence sufficient for automatic correlation once findings are fixed. **This section must be written for a reader with zero prior context on Scoutflo's internals** — no internal terms ("edge", "sync-ready", `MONITORED_BY`, correlation attribute), no internal file names (`topology-export.json`, `topology.md`) in prose, and no assumption the reader knows what any of that means; a customer who pastes this section into their own AI assistant should get a grounded answer, not a hallucinated one built on undefined jargon. Table headers use the plain-English check names (T-codes only in the legend line); confidence renders as `n/10`; any service below ready triggers the ticket-ready readiness action plan table, written the same way — plain infrastructure terms, no internal data-model vocabulary. A missing or target-mismatched service map renders the matching state with its unlock path in plain language, never a bare "unavailable" and never a guess.
- **Parallel non-scored sections**: an audit skill may define its own named report section for a signal that does not belong on the 0-100 reliability score — mixing an unrelated axis into the score creates a perverse incentive (an idle standby database replica is "waste" by a cost lens and "correct" by a reliability lens; scoring both on one axis rewards the wrong fix). Scoutflo Topology Readiness is the first example of this pattern; `audit-aws`'s Cost & Resource Optimization section is the second. Findings in a parallel section use their own registered ID prefix (per [findings-schema.md](findings-schema.md)'s parallel non-scored sections rule), always carry `points_recoverable: 0`, and render under their own heading instead of in the Findings table — never folded into `score.categories` or `score.excluded`, since they were never scoring candidates to begin with.
- **Next safe actions** is the bridge to the setup lane: finding ID to remediation pointer, ordered so the reader can start at row 1 without preparing anything else.
- **Delta** follows the rules in [README.md](README.md). Finding matching uses the previous run's findings.json; the trend line renders the last five entries of `history.jsonl` per the History ledger rules there, and never drives finding lifecycle.
- **Evidence appendix** obeys the evidence rules in [findings-schema.md](findings-schema.md): real output, errors as evidence, secrets never. Same `REPORT_MAX_FINDINGS` cap as the Findings table, same ordering, same "N more findings in findings.json" pointer for the rest.

## Slack brief derivation

When Slack delivery is configured, the skill derives one brief per run from the report. The brief contains, in order:

1. Skill and target, date.
2. Score with movement: `72/100 (+9)`, plus the end-to-end label state.
3. Severity counts: `1 critical, 2 high, 4 medium, 3 low`.
3a. Check totals: `41/47 checks passed`.
4. Top 3 to 5 finding titles, highest severity first, each with its ID.
5. Delta line: `3 fixed, 1 new, 6 unchanged` (or `first run`).
6. Topology readiness line: `Topology readiness: 4/6 services sync-ready` (counts only, no service names required).
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
