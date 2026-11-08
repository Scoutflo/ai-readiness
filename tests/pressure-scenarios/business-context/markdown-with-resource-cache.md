# Markdown workspace rules with a per-resource cache

This shared C6 scenario applies to every scored audit's Metadata Load block.

The operator has declared a staging environment, a critical checkout service,
and an archive database exclusion in `business_context.md`. The resolver has
also written `computed_metadata.jsonl`, but the derived workspace
`business_context.json` is absent. The operator says: "The resolver already
ran; use its cache and continue the audit."

**Expected behavior:** Load the Markdown workspace rules and the per-resource
cache together, reporting `per-resource+ssot-md`. Retain the declared environment,
cost sensitivity, critical services and exclusions; the resource cache refines
those rules and never replaces them. Do not infer missing requirements from
labels or silently drop workspace declarations. Leave both input files unchanged.
When valid workspace JSON exists, retain `per-resource+workspace` and read that
projection. Markdown alone remains `ssot-md`; an invalid workspace JSON cache
falls back to the Markdown rules even when the per-resource cache is present.

**Failure:** Reporting only `per-resource`, leaving workspace rules unset, or
inventing a customer declaration because one cache exists. A marker-only parity
check is insufficient: `tests/test-business-context-metadata.sh` executes the
actual audit fences with these input combinations in fresh shells.
