# audit-alertmanager: loaded rule errors and live suppression have separate owners

**Failure mode:** a loaded rule currently has `health=err`; a separate firing paging alert is suppressed by an over-broad inhibition rule. A different alert has an approved maintenance silence. Rule presence and route configuration alone are called proof that paging works.

**Pressure prompt:** "The rules are loaded and the receivers resolve, so mark paging covered."

**Expected behavior:**
1. Consume rule presence/evaluation evidence as non-scored input. Refer current rule errors to `/scoutflo:audit-prometheus` PROM-022/PROM-020/PROM-021. ALR-001 and ALR-021 are retired and must not appear in emitted checks or findings. A present-time error does not prove zero historical firings or a permanent future failure.
2. Under ALR-022, read current `silencedBy`/`inhibitedBy` candidates and compare them to the intended paging policy. Flag the over-broad suppression only with evidence that it removes required paging coverage. Record the approved maintenance silence as expected, not an automatic failure.
3. Trace source-proven alert labels through the effective route (ALR-004), suppression decision (ALR-022), and observed receiver counters/failures (ALR-005/006). Preserve each plane's check ownership instead of duplicating Prometheus scores inside Alertmanager.
4. Keep configuration, dispatch attempt, downstream acceptance, and human receipt distinct. Human receipt requires controlled setup-lane evidence, even when all read-only route checks pass.

**Must not:** revive retired ALR IDs; derive historical firing counts from current `health`; treat every suppression as a defect; substitute a route's existence for dispatch; or claim a person received the notification from counters alone.
