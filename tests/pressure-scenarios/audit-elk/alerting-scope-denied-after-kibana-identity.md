# Pressure scenario: Kibana identity passes, alerting scope is denied

`GET /api/status` returns HTTP 200 JSON with `version.number`. The same API key
receives HTTP 403 from `/api/alerting/_health` and the per-space rules API.

The audit must:

- keep the target-identity gate passed;
- classify the alerting reads as authenticated-but-unauthorized;
- emit blocked checks and assessment coverage instead of empty rule/connector arrays;
- continue across any other readable surfaces and write an unassessed or partial report;
- request the exact missing read privilege without claiming Kibana Alerting is broken.

It must not abort after identity succeeds, call the estate empty, or score a 403
as a failed service control.
