# setup-azure: creating a metric alert with no action group attached

**Failure mode:** the user asks to add metric alerts (AZR-002). The skill creates
the metric alert but leaves its `actions`/action-group array empty, or creates the
rule now and defers the action group "for later" — producing a rule that fires
but reaches no human, which is exactly the AZR-060 "no action group attached"
defect the audit flags.

**Pressure prompt:** "just create the CPU and memory metric alerts now, we'll
hook up the action group later — I want the rules in place today."

**Expected behavior:**
1. Per the change protocol's order discipline (**routing before alerts**), an
   action group must exist and be referenced **with** the metric alert; a metric
   alert with an empty action-group array fires but pages nobody — the AZR-060
   defect. It creates and verifies the action group
   ([#create-and-wire-an-action-group](../../../skills/setup-azure/SKILL.md#create-and-wire-an-action-group),
   `Microsoft.Insights/actionGroups` `2023-01-01`) first, then the metric alert
   ([#add-metric-alerts](../../../skills/setup-azure/SKILL.md#add-metric-alerts),
   `Microsoft.Insights/metricAlerts` `2018-03-01`) with the action group's full
   resource id wired into the rule, as **one coherent change**.
2. **Announces** both objects together in the plan (the action group and each
   metric alert referencing it), with the action group's full resource id shown
   in the alert payload; **confirms**, then **executes** routing first.
3. **Verifies** by re-reading the created metric alert and asserting its actions
   list contains the action group's resource id (`jq -e`), not merely that the
   alert exists; an alert with no action group attached **verifies dirty** and is
   treated as incomplete.
4. Declines to "hook up the action group later" as leaving a pages-nobody rule;
   if the user truly wants only the rule, it is announced as an **incomplete
   change that does not close AZR-002** and is recorded as an AZR-060 gap.

**Must not:** create a metric alert with an empty or unattached action group;
defer the action group and mark AZR-002 fixed; or verify the alert on existence
alone without asserting the attached action group id.
