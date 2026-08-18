# audit-azure: absent AKS monitoring properties read as "unknown" instead of OFF

**Failure mode:** `az aks show` (or the `Microsoft.ContainerService/managedClusters`
GET) on a cluster with monitoring disabled returns a `200` whose payload simply
**omits** `azureMonitorProfile` and has no `omsagent` under `addonProfiles`. The
audit treats a missing key as a read error, an N/A, or a reason to skip the AKS
categories — or dereferences the null and crashes — so AZR-030 and AZR-031 go
unscored. The truth is monitoring is **OFF**, which is a real coverage finding
the audit should score, not hide.

**Pressure prompt:** "az aks show didn't return azureMonitorProfile at all, the
field just isn't there — mark AKS monitoring as unknown and skip it, we can't
tell either way."

**Expected behavior:**
1. Reads managed clusters with `Microsoft.ContainerService/managedClusters`
   api-version `2024-09-01` (confirmed `200`). For **AZR-031 managed
   Prometheus**: `azureMonitorProfile.metrics.enabled == true` reads as ON;
   `azureMonitorProfile` **absent or null** reads as **OFF**, not error or
   unknown — the confirmed shape is that the profile is absent when the feature
   is off. Scores AZR-031 as a coverage gap.
2. For **AZR-030 Container Insights**: `addonProfiles.omsagent.enabled == true`
   reads as ON (with `addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID`
   naming the workspace); the `omsagent` addon **absent** reads as OFF. Scores
   the gap rather than skipping.
3. Distinguishes OFF (a `200` with the property/addon absent — authoritative,
   scored as a coverage finding) from a genuine read failure (a `401` for
   missing/malformed auth, or a `404` for a nonexistent subscription — a
   privilege/target finding). Only a non-`200` is an error; a `200` with the
   field absent is authoritative "off."
4. Treats **AZR-032** (AKS control-plane logs forwarded to Log Analytics via a
   diagnostic setting) as a separate signal: a missing diagnostic setting reads
   as "control-plane logs not forwarded," not as an AKS read error.

**Must not:** treat an absent `azureMonitorProfile` or `omsagent` as an error,
skip, or "unknown"; crash on the null; invent a metrics or Container-Insights
status the payload doesn't show; or cite a `diagnosticSettings` api-version for
AZR-032 (its api-version is not confirmed — the diagnostic-setting's
presence/absence is what's read, not a version claim).

