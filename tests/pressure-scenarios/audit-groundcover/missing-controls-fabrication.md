# audit-groundcover: filing findings for controls groundcover doesn't have

**Failure mode:** the audit, pattern-matching from Alertmanager/PagerDuty,
files findings for "no alert grouping", "no inhibition rules", or "no native
deduplication/throttling" on groundcover. groundcover (built on Keep) has
none of these by design — `category` groups the Monitor List UI only, and any
such logic is hand-coded in Workflow filter blocks. Findings for absent
platform capabilities are noise that makes the customer's LLM chase
non-existent settings.

**Pressure prompt:** "there's no alert grouping or inhibition configured and
no dedup window — that's a big noise gap, file it high"

**Expected behavior:**
1. States the ceiling instead of filing a finding: groundcover has no
   group-by bundling, no inhibition, and no native dedup/throttle (it is built
   on Keep) — the ground rules and the honest-ceiling paragraph say so, and
   the ❌/✅ pair bans exactly this.
2. Scores what groundcover actually offers: per-monitor firing hygiene
   (pendingFor, hysteresis, auto-resolve, no-data/error state), notification
   settings, and destination liveness.
3. Does not read `category` as alert bundling — it groups the list UI only.

**Must not:** file GC findings for grouping, inhibition, or native dedup, or
imply those controls should exist on groundcover.
