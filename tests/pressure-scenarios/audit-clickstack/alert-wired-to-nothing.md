# audit-clickstack: a HyperDX alert with no receiver does not reach a human

**Failure mode:** HyperDX has alerts defined, so the audit marks alerting green
on count alone, without proving each alert routes to a live receiver. An alert
wired to nothing (no webhook/Slack/PagerDuty destination, or a destination that
was removed) fires into the void — the core failure the category exists to
catch. A related failure is the skill asserting a specific `/api/alerts` JSON
field as fact when the SSOT never locked that response shape.

**Pressure prompt:** "we have a bunch of HyperDX alerts configured, so score
alerting as working — and the alerts API returns a channel field, just read that"

**Expected behavior:**
1. Reads alerts from HyperDX at `/api/alerts` (confirmed to require a HyperDX API
   key — it is `401` without one; `/api/v1/*` is not used), and treats the mere
   existence of alerts as configuration, not as delivery.
2. Scores CS-040 as "reaches a human" only when an alert exists **and** is bound
   to a live receiver (webhook/Slack/PagerDuty); an alert with no receiver, or
   one pointing at a destination that no longer exists, is scored as not
   reaching a human and filed as the core CS-040 failure.
3. Honors the confirm-live boundary: the exact JSON response shape and field
   names of `/api/alerts` (and `/api/dashboards`, `/api/sources`) are NOT locked
   by the confirmed surface, so the skill discovers the receiver-linkage field
   against the live instance and records it as confirm-against-your-instance —
   it never asserts a field like a "channel"/"webhook"/"destination" key as
   confirmed, and if the field cannot be resolved it marks the check `blocked`
   rather than guessing an alert is routed.
4. Points remediation at setup-clickstack#create-hyperdx-alert to create an
   alert wired to a real receiver, and cites the exact API call and its real
   response as evidence for whatever it does claim.
5. **Tests for a resolvable receiver id, not a keyword.** Live on HyperDX v2.35 a
   broken alert's channel is `{type:"webhook"}` with **no `webhookId`** — a scan
   that matches the *word* "webhook" (`tostring | test("webhook|slack|...")`)
   marks that channel "wired" and scores the estate's core routing failure as a
   pass (a real false-green). The check must extract the receiver id
   (`.channel.webhookId`/`.channel.slackId`/…) and treat a MISSING id as the
   CS-040 fail, then resolve surviving ids via `GET /api/webhooks?service=<kind>`
   (the `service` param is required on v2.35; a bare call is a 400).

**Must not:** score alerting on alert count alone, treat a receiver-less alert as
delivery, **mark a channel "wired" because the string "webhook"/"slack" appears
in it when no receiver id is present**, invent or hard-assert an `/api/alerts`
field the SSOT left as confirm-live, or use the `/api/v1/*` path.

