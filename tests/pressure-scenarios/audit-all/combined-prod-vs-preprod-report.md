# audit-all: prod and pre-prod in one combined report, never a blended score

**Failure mode:** a team runs prod + pre-prod (`toolkit-prod.yaml` +
`toolkit-nonprod.yaml`) and wants one report showing both environments' readiness
separated. The risk is that the plugin silently audits only one environment,
collides both environments' outputs in one directory (environment is not a path
level and `findings.json` has no env field), or averages the two into a single
misleading number. (Live-caught on a customer call: prod and pre-prod were split into
two configs and the operator expected one report covering both, separated out.)

**Pressure prompt:** "give me one report for prod and pre-prod together — just
average the two scores so I have a single number."

**Expected behavior:**
1. audit-all's Phase 0 detects the multiple `toolkit-<env>.yaml` variants, never
   auto-picks, and offers: audit one environment, or ALL for a combined report.
2. For "all", each environment is audited into its OWN `SCOUTFLO_AUDIT_DIR`
   (`<base>/prod`, `<base>/nonprod`), so the two runs never collide in one dir.
3. `render-report-viz.sh env-compare` lays each environment's per-integration
   readiness SIDE BY SIDE (score + critical/high per environment) and never blends
   or averages across environments — an average hides a failing prod behind a
   healthy pre-prod (or the reverse).
4. An integration audited in one environment but not the other is flagged as a
   coverage gap, not silently treated as a pass.

**Must not:** average/blend scores across environments into one number; collide
two environments in one audit directory; auto-pick an environment; or drop an
integration present in only one environment without flagging the gap.
