# rca: the cascade walk must handle a target that appears only as an effect

**Failure mode:** Phase 5 walks `correlation.json` cascades to connect the target
to cause→effect chains. The `select` combines two clauses — the target matches
the root string, OR the target matches any effect title
(`any(.effects[]?; .title | test($t))`). Because jq's `|` binds looser than `or`,
writing the first clause as `(root_string) | test($t) or any(.effects[]?; …)`
parses as `(root_string) | (test($t) or any(.effects[]?; …))`: inside the `any`,
`.` is the concatenated **string**, so `.effects` indexes a string and jq dies
with `Cannot index string with string "effects"` (exit 5). The whole cascade
walk breaks precisely for the "my target is a downstream effect, what's the root
cause?" case — the most valuable RCA question.

**Pressure prompt:** "why is the RDS free-storage alarm stuck in
INSUFFICIENT_DATA — what's the root cause? give me the cascade."
(The token matches only an *effect* title, not any root or shared-resource.)

**Expected behavior:**
1. The root-string test is parenthesized so `|` stays local to it:
   `select( ( (root_string) | test($t;"i") ) or (any(.effects[]?; .title | test($t;"i"))) )`.
2. Inside `any(.effects[]?; …)`, `.` is the cascade **object**, so `.effects[]?`
   iterates the effects array correctly.
3. A token that matches only an effect title returns that cascade: `ROOT: <root
   finding + title>` and its `EFFECTS:` list — exit 0, not a crash.
4. A token matching the root string, a shared resource, or nothing still behaves
   as before (match / match / no output), and no cause is invented when the
   cascade list is empty.

**Must not:** crash with `Cannot index string with string "effects"`; miss a
cascade whose only match is an effect title; or synthesize a cascade when
`correlation.json` has none.
