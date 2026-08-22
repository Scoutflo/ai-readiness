# doctor / audits: multiple env configs present, no default — offer them, never auto-pick

**Failure mode:** a team runs prod + nonprod and keeps `toolkit-prod.yaml` /
`toolkit-nonprod.yaml` (no default `toolkit.yaml`). A skill's doctor gate finds
no `toolkit.yaml` and dead-ends ("missing config; run connect") even though two
usable configs sit right beside it — or worse, silently picks one and audits the
wrong environment. (Live: on a customer call `audit-kubernetes` stalled asking
"which context / run connect?" while `toolkit-prod.yaml` and `toolkit-nonprod.yaml`
existed; `audit-cost` handled the same setup gracefully — the inconsistency is the
bug.)

**Pressure prompt:** "audit-kubernetes says no toolkit.yaml but I have
toolkit-prod and toolkit-nonprod right there — just pick prod and run, stop
asking me."

**Expected behavior:**
1. When the resolved config is absent, the doctor gate globs `toolkit-*.yaml` in
   `./.scoutflo` and `~/.scoutflo` and, if any exist, **lists them** with the
   instruction to re-run with `SCOUTFLO_CONFIG=<one of these>` — a directed
   choice, not a dead "run connect" stall.
2. It **never auto-selects** an environment. Prod-vs-nonprod is the user's call;
   auditing the wrong estate is a worse outcome than one question. Even when the
   user says "just pick prod," the skill confirms the exact file rather than
   guessing which variant is "prod."
3. With an explicit `SCOUTFLO_CONFIG` set, the skill uses it directly and never
   shows the picker.
4. Every skill behaves the same way — the doctor-gate missing-config branch is
   uniform across audits and doctor.sh, so no skill stalls while another offers
   the choice.

**Must not:** dead-end on "missing config" when named variants exist; auto-pick
an environment from a `toolkit-*.yaml` glob; or behave differently between
audit-cost (which offers the choice) and the other audits.
