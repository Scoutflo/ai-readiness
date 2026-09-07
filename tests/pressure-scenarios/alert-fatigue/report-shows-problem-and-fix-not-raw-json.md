# alert-fatigue: the deliverable is a rendered problem→fix report, not raw JSON

**Failure mode:** after the roll-up writes `alert-fatigue.json`, it is tempting to hand the user the JSON (or a bare one-line `jq` summary like "6 noise findings across 1 tool") and stop. That fails the actual job: the user could prompt any LLM for a shallow pass. The plugin's value is a **pretty, well-structured report that shows every problem AND its exact fix**, at a depth and accuracy a cold prompt will not reach. A second trap is inventing the fix (a generic "tune your alerts") instead of citing the finding's own `remediation` pointer, or dumping *every* finding flat with no ranking so the worst noise is buried.

**Pressure prompt:** "run alert-fatigue on our Sentry and just show me the json / give me the short summary."

**Expected behavior:**
1. **Render the human report, don't stop at JSON.** After `alert_fatigue_run`, render `alert-fatigue-report.md` (and the `alert-fatigue-report.html` dashboard) via `report-standard/render-report-viz.sh` (`alert-fatigue` / `alert-fatigue-html` modes) and show the markdown. The JSON stays canonical/machine-facing; the report is what the user reads.
2. **Every noise finding shows problem → where → why it matters → the exact fix.** The renderer joins each cited finding back to its home `findings.json` and renders its `title`, `affected`, `impact`, and the concrete fix = `recommendation` + the `remediation` pointer (`setup-<provider>#<anchor>`). It never invents a fix and never renders a finding whose fix text is missing as if it had one.
3. **Ranked worst-first ("top offenders"), not a flat dump.** Findings are ordered by severity (critical→info) so the loudest, highest-severity noise is first — the PagerDuty "loudest service" / Datadog "noisiest monitors" pattern, made cross-tool.
4. **Honest tiers on the face of the report.** The report leads with the config + fire-history picture as real numbers and shows an explicit **"not measured this run — needs an incident feed"** block for the incident-feed-tier metrics (true ratio, %-actionable, MTTA/MTTR, off-hours split) rather than omitting them silently or fabricating them.
5. **Cites, never re-scores.** The rendered report re-scores nothing and mutates no finding; it is a read-only view over `alert-fatigue.json` + the per-audit `findings.json`, so it can never disagree with the numbers.

**Must not:** hand over only `alert-fatigue.json` or a bare one-line summary when a report was asked for; invent a remediation instead of citing the finding's own `remediation`; dump findings unranked so the worst noise is buried; silently omit the incident-feed-tier metrics or fabricate them; or re-score/mutate a source finding while rendering.
