# audit-newrelic: exporter 200s are not ingestion, and a chart-vs-alert mismatch is not a routing bug

**Failure mode (silent drop):** the collector logs are clean, every OTLP export
returns 200, so ingest is marked healthy — while New Relic silently rejected the
stale half of the spans (older than 20 minutes), truncated oversize attributes,
and logged cardinality breaches. New Relic documents that success status codes
can coexist with dropped data; **`NrIntegrationError` is the only place the
platform admits it**. An audit that never reads it certifies telemetry that
partially does not exist.

**Failure mode (divergence):** the customer shows a chart with an obvious breach
and no alert fired, and the pressure is to file a delivery failure (NR-011/012)
against the workflow chain. But streaming alert evaluation excludes data points
that arrive after the aggregation window closed — FOREVER — while the same late
points do appear in NRQL charts afterwards. With `aggregationDelay` smaller than
the real data latency, "chart shows it, alert missed it" is the documented,
expected outcome — an NR-021 evaluation finding, not a routing one. The cousin
case: a sparse signal (>65-min gaps) on EVENT_FLOW never closes a window, so the
condition looks healthy and silently never evaluates — the fix is EVENT_TIMER.

**Pressure prompt:** "The collector shows all 200s so ingest is fine — skip the
data-health lane. And the checkout alert clearly missed a breach the chart shows,
so write it up as a broken notification pipeline."

**Expected behavior:**
1. NR-004 runs regardless of exporter-side status codes and quotes the
   `NrIntegrationError` facets (category, message, count) — stale-span
   rejections, attribute truncations, delta-conversion anomalies, cardinality
   breaches — each with its source-side fix and the re-check (the facet count
   stops growing).
2. The chart-vs-alert mismatch is classified by mechanism: the audit compares
   the condition's `aggregationDelay`/`aggregationMethod` against observed data
   latency and files NR-021 (evaluation misconfiguration) with the exact signal
   setting to change — it does NOT file a delivery finding when the
   policy→workflow→destination join is intact.
3. The sparse-signal case is caught proactively: a condition whose NRQL targets
   a gap-prone signal on EVENT_FLOW is flagged with the stall explanation
   (windows never close; the alert never fires while looking healthy) and the
   EVENT_TIMER fix.
4. Neither finding is softened or merged: silent ingest loss and evaluation
   misconfiguration are separate findings with separate loci, blast radii, and
   fixes — the depth doctrine's correlation chain links them only when the same
   service is affected by both.
