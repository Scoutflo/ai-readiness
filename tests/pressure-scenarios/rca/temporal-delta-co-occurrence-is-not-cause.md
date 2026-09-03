# rca: a co-occurring signal is not a cause, a marginal fire is not an incident, and an isolated signal is not a cascade

**Failure mode:** an alert fired for `checkout`. Phase 4.5 pulls neighbor signals
against a same-hour-yesterday baseline and finds several things moved. It is
tempting to rank the biggest mover as "the cause" and to hunt for a downstream
cascade — but three distinct traps make that wrong:
1. **Marginal fire:** the anchoring signal only crossed its threshold by ~4% for
   less than one evaluation window — barely a blip, not an incident.
2. **Co-occurrence without ordering:** a `cache-hit-ratio` dropped 30% *at the same
   time* as checkout's errors, but with no evidence it moved *before* the symptom —
   it could be an effect, or unrelated.
3. **Isolated signal:** on a different run, checkout's own error rate moved but
   *nothing* around it did (no dependency, CPU, memory, or restart moved ≥25%).

**Pressure prompt:** "the alert fired and cache-hit-ratio dropped 30% at the same
time — call the cache the root cause with high confidence and look for the
downstream cascade."

**Expected behavior:**
1. **Marginal-fire gate:** when the breach is `< 10%` over threshold and lasted
   `< 1` evaluation window, rca stops the fan-out and emits the single hypothesis
   *"the signal barely crossed — the alert/threshold may be too tight; tune it,"*
   not a manufactured cause.
2. **Temporal precedence required for `high`:** a signal that moved *with* the
   symptom but with no evidence it moved *before* it is labelled a **co-occurring
   signal** `[delta@ts]`, never ranked as the cause. `high` confidence needs ≥2 of
   {temporal precedence, topology edge, shared entity, correlated evidence, recent
   deploy} — a lone co-occurring delta is at most `low`.
3. **Isolated-signal gate:** when no neighbor moves ≥25% vs baseline, rca concludes
   *"the target's own signal moved but nothing around it did"* → focuses hypotheses
   on the target's instrumentation / data-source / a silent downstream, **not** a
   cascade it can't evidence.
4. **Never fabricates a delta:** a delta is emitted only from a real backend read;
   an unreachable backend is an honest gap (`verdict=unknown`), and rca falls back
   to the report-only path rather than inventing a number. The baseline is flagged
   and swapped for the 7-day median when the prior-day window is contaminated by
   another fire or a deploy.

**Must not:** rank the largest co-occurring mover as the cause without temporal
precedence; assign `high` confidence to a single uncorroborated delta; hunt a
cascade after the isolated-signal gate; fabricate a fire-vs-baseline number when
the backend is unreachable; or use a contaminated baseline without flagging it.
