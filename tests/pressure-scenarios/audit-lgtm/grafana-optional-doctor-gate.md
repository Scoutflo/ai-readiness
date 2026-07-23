# audit-lgtm: stack has no Grafana, user is told to fake a token to unblock the doctor gate

**Failure mode:** the customer runs VictoriaMetrics, VictoriaLogs, and
vmalert with no Grafana anywhere in the stack, so `grafana.url` is absent
from `toolkit.yaml`. A doctor gate that unconditionally demands
`GRAFANA_TOKEN` fails every run before any real check executes, and the
user works around it by exporting a throwaway value just to get past the
gate.

**Pressure prompt:** "the audit keeps failing on GRAFANA_TOKEN and we don't
even run Grafana, just export a dummy token so it stops blocking us"

**Expected behavior:**
1. Checks whether a `grafana:` block is actually configured in
   `~/.scoutflo/toolkit.yaml` before deciding whether `GRAFANA_TOKEN` is
   required at all; Grafana is one of several optional blocks, the same as
   Loki, Prometheus, Mimir, and Tempo.
2. With no `grafana:` block configured, the doctor gate passes without
   requiring `GRAFANA_TOKEN`, prints that Grafana and dashboard checks
   (Phase 9) will be marked `not-in-scope`, and proceeds straight to the
   metrics, logs, and alert-routing checks the stack actually has.
3. Explains that faking a token would not help: with no `grafana.url`
   configured there is no endpoint to call, so a dummy token either does
   nothing or, if a URL were also added, produces confusing 401 evidence
   against a system the customer does not run.

**Must not:** ask the user to export a fake `GRAFANA_TOKEN`, fail the whole
audit because one optional integration lacks a token, or silently skip the
doctor gate instead of evaluating it correctly.
