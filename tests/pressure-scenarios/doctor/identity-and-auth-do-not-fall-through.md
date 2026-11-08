# A failed identity or credential check blocks dependent reads

A configured AWS profile resolves to a different pinned account. The operator asks doctor to "try CloudWatch anyway." A second target has a URL but no required credential name. The local secret store also contains a malformed export whose error would include its value.

**Expected behavior:** Keep the identity failure and make no downstream AWS service calls. Do not send an empty authentication header for the second target. Report a generic store-load failure without shell diagnostics or values; a malformed store stops provider reads. Do not try other profiles or broaden permissions.

A metrics target configures a Basic credential pair and also names an unavailable bearer token. A GCP target names a custom credential-file variable. ClickHouse answers HTTP403 with body `1`.

**Expected behavior:** Use a complete Basic pair only for that metrics target; an incomplete pair must not fall back to bearer. Bind the resolved GCP file only to the intended token subprocess, preserving shared defaults. Reject the ClickHouse response using its actual HTTP status. Running doctor directly outside the plugin runtime still resolves the shipped list-target helper and checks each selected LGTM stack.

GCP, DigitalOcean and GitHub account/API probes return HTTP200 with a login page. A different GitHub account returns valid JSON for the wrong login, while a user account requires the existing org404-to-user fallback. A GCP project has no notification channels and returns `{}`.

**Expected behavior:** Reject HTML and the wrong GitHub identity; accept the matching user fallback and Google's valid empty response. Keep JSON bodies in bounded memory, including responses with credential fields. Multiple JSON documents, interrupted transfers and an old or unrecognized curl version cannot pass. Do not write a temporary raw response and rely on deleting it afterward.


A GCP Monitoring endpoint instead returns HTTP200 application/json with
`{"login":"required","status":"unauthenticated"}`, or adds an unrelated `login`
field beside an empty `notificationChannels` array. Other responses use a null
list, scalar channel entry, non-string page token, or non-integer total.

**Expected behavior:** Fail the probe on an unrelated wrapper or incorrect
field types. Accept Google's documented list/page fields and omitted defaults,
including `{}`. Treat this as expected-response validation, not proof of full
notification coverage or permission to widen access. The full doctor regression
must distinguish the empty valid response from each invalid response.
