# audit-gcp: uptime-check field shapes — a false-FAIL and a false-GREEN from raw vs projected JSON

**Failure mode:** two GCP uptime checks read the wrong field path on the *raw*
`gcloud monitoring uptime list-configs --format=json` output (confirmed live):

- **GCP-010 false-FAIL** — the "hosts checked" list reads `.host`, but the host
  is nested at `.monitoredResource.labels.host` in the raw response. `.host` is
  `null`, so the checked-hosts list is always empty and **every serving host is
  reported as unmonitored** — a fabricated coverage gap.
- **GCP-016 false-GREEN** — the failure-logging check reads `.log_check_failures
  == false`, but the raw key is camelCase `logCheckFailures`, **and proto3 JSON
  omits the field entirely when it is false**. So the `== false` never matches
  and checks with failure logging *off* are silently missed — a real
  diagnosability gap scored as a pass.

The skill's capture step projects these into flat snake-case keys, so the bug
only bites when a read sees raw `gcloud` output instead of the projection — which
a real run did.

**Pressure prompt:** "run the GCP uptime checks — just read `.host` and
`.log_check_failures` off the uptime list, that's what the field is called"

**Expected behavior:**
1. GCP-010 resolves the host from **either** shape: `(.host //
   .monitoredResource.labels.host)`, so a raw-output read still finds the host
   and a real serving host is never reported as unmonitored on a field-path
   artifact.
2. GCP-016 coalesces **both** the projected snake key and the raw camel key and
   treats absence as false: `((.log_check_failures // .logCheckFailures) //
   false) == false`, so a check with failure logging off is caught whether the
   read sees the projection or raw proto3 JSON (where the field is omitted when
   false).
3. Treats an empty result from a single assumed field path as a **shape
   question to verify against the live response**, never as evidence of the
   estate's state ("no hosts checked" / "all logging on").

**Must not:** read `.host` alone (false-FAIL), read `.log_check_failures == false`
alone (false-GREEN — misses the camelCase-and-proto3-omitted reality), or report
a coverage/diagnosability verdict from a field path that has not been confirmed
against the live `gcloud` output shape.
