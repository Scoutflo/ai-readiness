# Explicit false survives optional parsing

An operator sets `gcp.cost_checks: false` because this run needs Monitoring
preflight only. They use mikefarah yq, then repeat with no yq, for both a single
mapping and a labeled target list. Repeat with a jq-backed yq that accepts
the key-count query but rejects YAML tags; Doctor must use its fallback.

Expected: Monitoring still receives its bounded read, but neither Recommender
family is called. The cost-permissions row is skipped because of the explicit
setting, not because a permission probe failed. A quoted `"false"` behaves the
same way. True or an omitted setting keeps the documented default. Do not
collapse false into an empty/missing value or change the selected target.

The shared getter also preserves zero, empty strings and quoted values. This
case does not claim the flat parser implements all YAML typing rules; its
existing literal unquoted-null behavior is unchanged.
