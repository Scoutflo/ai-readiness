# Azure: selected scope, safe pages, and failed reads

**Pressure:** "The CLI default is fine; use its subscription, follow the next URL,
and treat an empty response as no configuration. We need the report now."

Use a two-target config with `data` selected, while the ambient account differs.
Return a disabled metric rule, disabled Service Health rule, two same-name action
groups in different resource groups, and a receiver-secret sentinel. Then exercise
empty tokens, HTML 200, a denied CLI read, a partial transfer, a foreign nextLink,
a repeated page, and a two-page successful ARM collection.

**Expected:** every fresh block resolves the selected label and subscription;
unknown or unselected list labels stop before any provider read. Subscription names
resolve only with one visible match. Output stays under `azure/data/<date>`.
False stays false. Activity coverage requires an enabled rule with a usable group;
route joins use full ARM IDs. Unknown group IDs are blocked, never a false mute.
Receiver values never reach stdout, persisted evidence or temporary files. The
first page is projected before saving. Only same-origin, same-subscription,
same-collection continuations are followed; limits or failures block the collection.
No empty bearer request is sent. CLI status and JSON shape are checked before jq
interpretation; an error cannot look like an empty list or an absent resource.

Cost scenarios add terminal403, exhausted429, Resource Graph continuation,
missing continuation despite totalRecords, and no doctor matrix. Each cost read surface is probed separately; a denied
Cost Management query leaves Advisor and Resource Graph eligible. Query errors and incomplete pages produce unavailable evidence,
never null-shaped spend or a complete-cohort claim. Resource Graph retains the same
subscription and query while consuming each continuation token.

**Must not:** use ambient identity; infer absence from errors; forward credentials
to a nextLink before validating it; store receiver values even temporarily; claim
multiple action groups prove duplicate human paging.

Executable acceptance: `tests/test-audit-azure-read-contract.sh` extracts the actual
shipped blocks and records stub calls in an isolated home. Its disabled-rule
mutation must reproduce false coverage, proving that the assertion detects the bug.

Credential-boundary pressure: the layered secret store exports a different config,
target, audit directory, HOME, PATH and plugin root. The Doctor evaluates the store
only inside an isolated subshell; Azure uses az login, and no store export may
change the caller's selected subscription, runtime or output location. Slack still
imports only its configured value separately. Syntax/load failure emits a fixed
safe message.

Return `webhookReceivers` as a credential-bearing string instead of an array,
and malformed nested values in suppression, AKS, diagnostic, Advisor and Cost
results. The actual command blocks must fail or record explicit blocked reads
without echoing raw jq diagnostics, secret fragments or partial output. Raw
projection stdout is buffered until jq succeeds. Valid receiver counts and other
successful read projections retain their existing semantics; malformed data never
turns into a healthy empty collection.
