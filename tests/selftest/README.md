# Scoutflo AI Readiness — local self-test mechanism

A reusable, layered test harness you run locally to prove the whole plugin still
works — mechanically and on real data. One entrypoint, opt-in layers, an honest
PASS/FAIL/SKIP matrix. It is the regression memory: every bug a rigorous test
run found is a permanent case here, so it can never silently come back.

## Quick start

```bash
sh tests/selftest/run.sh                 # hermetic layers (fast, no creds): mechanical + validators + capstone
sh tests/selftest/run.sh --layer validators
sh tests/selftest/run.sh --layer integration     # spins ClickStack in Docker, probes, tears down
sh tests/selftest/run.sh --layer live --dir ./scoutflo-audits   # doctor + validate your real audit outputs
sh tests/selftest/run.sh --keep          # keep the scratch workdir for inspection
```

Exit code is `0` only if every non-SKIP case passed. The matrix is written to
`tests/selftest/last-run.md` (worst-first) and printed as a live checklist.

## The layers

| Layer | What it proves | Needs | Hermetic |
| --- | --- | --- | --- |
| **mechanical** | leak-scan, structure-check (13), run-tests (all suites), `plugin validate --strict` all pass | jq, claude CLI | ✅ |
| **validators** | the report-standard validators ACCEPT valid output and REJECT every invalid class; `render-report-viz` renders every mode; leak-scan catches real leaks and exempts placeholders/decimals/UUIDs | jq | ✅ |
| **capstone** | `correlation-engine` joins a shared resource across audits; `cost-analysis` rolls up and never invents a dollar | jq | ✅ |
| **integration** | a real ClickStack (Docker all-in-one) provisions healthy with the `otel_*` tables, then tears down | docker | opt-in |
| **live** | `doctor` connectivity sweep runs; every real `findings.json`/`report.md` in `--dir` passes the validators + leak-scan | `~/.scoutflo` creds, a real audits dir | opt-in |

`all` (the default) runs the three hermetic layers. `integration` and `live` are
opt-in because they need a Docker daemon and your real credentials/outputs
respectively — they record `SKIP` (never a fake pass) when their prerequisites
are absent.

## What the validators layer guards (the regression cases)

Derived at runtime from the single golden fixture in `fixtures/valid/` (synthetic
ClickStack output — no secrets), so there is one source of truth to maintain:

- **check-findings**: valid→pass; and reject — overall not reconciling, weights≠100,
  severity-histogram mismatch, missing `affected`, empty `remediation`, bad
  severity/status enum, malformed/duplicate id, `end_to_end` below the gate,
  a **string `overall`** and a **missing `score` envelope** (these two must fail
  *cleanly* — the rigorous test found they used to crash with a raw jq/shell error
  or the wrong exit code), and non-JSON.
- **check-report**: valid→pass; and reject — missing `## Inventory` section,
  inventory `counts.total` mismatch, wrong inventory schema, non-H1 first line.
- **leak-scan**: clean→clean; flag a real 12-digit account id (standalone and in
  an ARN) and an inline secret; and **exempt** the `123456789012` placeholder, a
  long decimal (`…317542016506`), and an all-digit UUID segment — the last two
  are false positives the rigorous test found.
- **render-report-viz**: every mode renders; a `|` in an inventory item name stays
  escaped (table not broken); the at-a-glance "Start here" breaks a points tie by
  severity (a critical is never buried under an equal-points medium).

## Full live sweep (LLM-driven)

Audits are executed by Claude reading the skill, not by a shell script, so the
end-to-end "run every audit against real data" pass is a short Claude playbook
that reuses this harness for validation. See **[PLAYBOOK.md](PLAYBOOK.md)**.

## Extending it

Add a regression case by adding one line to the relevant `vf_*` block in
`run.sh` (a jq/sed mutation + the expected exit). Keep fixtures synthetic and
secret-free. When a new bug is found in the field, add its case here first (it
should go red), then fix the code (it goes green) — that is the mechanism.
