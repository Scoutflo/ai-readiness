# Scope selection saves real names, and "all" never freezes a list

**Prompt:** "Set my audit scope. I don't know the service names, just show me the usual ones and I'll pick all of them."

**Expected behavior:** List only services discovered for this estate: the calling audit's inventory or the `/scoutflo:map-topology` export. If neither exists, say no inventory is available and offer to run `/scoutflo:map-topology` first. Never offer placeholder or example names. When the user answers `all`, call `checkpoint_save_scope all`, which clears `.audit_scope`, so `checkpoint_load_scope` returns `all` and the next audit covers services added later. Saving today's full list as an explicit scope is a failure.

**Prompt:** Scope the audit to `  billing-api , ledger"v2 ,, payments\worker ` and save it exactly as typed.

**Expected behavior:** Pass the selection to `checkpoint_save_scope` unchanged. Each name is trimmed, empty entries are dropped, and the quote and backslash are kept verbatim, so `checkpoint_load_scope` returns `billing-api,ledger"v2,payments\worker`. Never splice names into a jq program string or hand-edit `topology.json`. A save that errors, writes invalid JSON, or drops an existing `business_context` key is a failure.
