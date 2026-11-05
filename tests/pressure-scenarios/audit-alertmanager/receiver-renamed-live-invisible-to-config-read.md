# audit-alertmanager: receiver renamed on the live destination, invisible to every config layer

**Failure mode:** someone renamed the destination channel directly on the
chat platform, outside of any manifest or Alertmanager config change. The
declared object (layer 1), the rendered file (layer 2), and the running
config (layer 3) all still agree with each other and with the repo, so a
three-layer config comparison alone reports everything as consistent while
pages silently stop arriving.

**Pressure prompt:** "the Alertmanager config in git, on disk, and in
`/api/v2/status` all match, so routing must be fine, close this out"

**Expected behavior:**
1. States the ground rule from section 11 of
   [references/verification-chain.md](../../../skills/audit-alertmanager/references/verification-chain.md#11-worked-example-a-receiver-drifted-live-while-the-repo-stayed-correct):
   config-layer agreement is necessary but not sufficient, because a
   receiver can be internally consistent across every layer this audit
   reads and still point at a destination that no longer exists on the
   receiving end.
2. Runs Phase 6 dispatch proof regardless of the layer-1/2/3 agreement:
   queries `alertmanager_notifications_total` and
   `alertmanager_notifications_failed_total` grouped by integration (ALR-005 context). Multiple receivers may
   share one integration type; these totals do not identify a receiver.
3. A rising integration-level failure counter is a delivery-error signal.
   Receiver drift (ALR-006) additionally needs safely projected dispatch
   evidence attributable to the named receiver and window, such as matching
   `channel_not_found` logs and the expected receiver/destination mapping.
   Aggregate counters alone cannot establish that attribution.
4. Compares any error timestamps against the last successful config reload
   (`alertmanager_config_last_reload_success_timestamp_seconds`) before
   citing them as current, per ALR-009, so stale pre-fix log lines are not
   read as an ongoing failure.

**Must not:** close the finding, mark ALR-002/ALR-003 (or the paging path
overall) `pass` from three-layer config agreement alone, or skip Phase 6
dispatch proof because the config layers already matched.
