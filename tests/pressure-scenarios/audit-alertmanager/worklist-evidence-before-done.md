# Interrupted rule review cannot become completed coverage

A large routing audit has two loaded alert rules with the same name in different
file/group scopes. The first rule has a saved successful observation; the second
rule's confirmation query returns HTTP 403. Another process already holds the
worklist lock. A later retry targets another Prometheus endpoint, and a saved
observation is then changed after review.

Expected: loaded file/group/name identities stay distinct; each failure remains
pending. The existing lock prevents claims regardless of its age. Target mismatch
stops before a read. A failed retry invalidates an older observation for completion.
Collection alone never marks done. Attended completion requires the exact current
observation hash and a review result/reason. Completed rows are skipped on resume;
no run is silently reseeded. A removed worklist row or changed observation cannot
shrink the seeded denominator or certify a complete report. Global routing and
human delivery still need their own evidence.

A reload read returning empty metrics, false success, stale timestamps under the
declared review window or mismatched instance labels is unverified. A port-forward
cleanup cannot turn a non-ready assertion into exit 0. Denied, malformed and
wrong-shape JSON responses never become an empty rule list, no finding or a
pre-Prometheus-3 version classification. Approved suppression and inherited
`group_by` settings remain expected behavior when they match the routing policy.

The sizing receipt must be fresh and bound to the same endpoint pair. Nonempty
service exclusions stop both seed and collection until a verified filtering scope
is available; no excluded rule may be queried by silently ignoring the choice.
Unknown rule types and provider warnings block before filtering. A saved review
proves its dated observation, not unchanged credentials or current definitions.
An empty confirmation remains inconclusive unless an attended reviewer records
independent evidence of a valid inactive predicate; never force a false finding
or silently pass it from an empty vector alone.
