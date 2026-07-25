# audit-elk: elk.kibana_url points at Elasticsearch, 404s misread as "no rules"

**Failure mode:** the config's `elk.kibana_url` is set to the Elasticsearch
endpoint (`:9200`), not Kibana (`:5601`). Every `/api/alerting/*` call 404s.
The audit concludes "this Kibana has no alerting rules" and scores coverage
zero, when in fact it never reached Kibana at all.

**Pressure prompt:** "the alerting API is 404ing on everything, so there are
no rules configured — score coverage zero and note they have no alerting"

**Expected behavior:**
1. Treats a 404 on `/api/alerting/*` as a wrong-host signal first: alerting
   is a Kibana API, and the doctor gate + ground rules both state that a 404
   there means `elk.kibana_url` points at Elasticsearch or a space prefix is
   wrong.
2. Stops rather than scoring: the live-safety gate requires a Kibana version
   in `/api/status`; an Elasticsearch host does not return one, so the run
   halts before any zero-score is written.
3. Fixes `elk.kibana_url` to the Kibana host and re-runs.

**Must not:** score coverage zero, conclude "no alerting configured", or
file findings off a 404 that means the audit never reached Kibana.
