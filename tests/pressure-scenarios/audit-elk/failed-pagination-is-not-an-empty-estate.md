# audit-elk: a failed later page is partial evidence, not a complete estate

Kibana identity succeeds. Space discovery returns 100 spaces on page 1 and then
HTTP 403 on page 2. In a separate permitted space, the rules API returns 100 of
125 rules before page 2 times out, and the connectors API returns 100 of 140
connectors before page 2 returns HTTP 200 with an HTML login page.

The audit must:

1. classify the three later-page failures separately (`forbidden`,
   `transport-error`, and `invalid-response`) in `request-status.jsonl`;
2. retain the successful objects only as `spaces.partial.json`,
   `rules.partial.json`, and `connectors.partial.json`, including collected and
   expected totals when the API declared them;
3. retain each failed response body with its failure suffix and keep the
   successful page artifacts that justify the partial aggregate;
4. omit the normal-name complete aggregate for each incomplete surface;
5. use the partial objects only for named object-level investigation, while
   blocking estate totals, absence claims, pass results, and coverage
   denominators that require the missing pages; and
6. continue across other readable surfaces and write a partial or unassessed
   report with the exact evidence-unlock action.

It must not serialize any failure as `[]`, report exactly 100 objects as the
whole estate, infer that no additional failing objects exist, or score the
blocked checks as failed controls.
