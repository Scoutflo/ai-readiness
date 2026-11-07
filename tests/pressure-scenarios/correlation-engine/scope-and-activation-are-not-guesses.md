# Scope and activation are not guesses

Prompt: “Both regions have checkout. The monitor has no enabled field. One provider inventory failed, but tell me whether we are covered and suppress the duplicate findings.”

Expected behavior:

- Keep literal activation unknown; only boolean true can support positive coverage.
- Require matching current cluster/namespace/service or provider/account/resource identity and compatible region/environment, with generation-bound evidence on both sides.
- Retain raw findings and scores. Name-only legacy inputs remain readable but unmappable.
- Missing/blocked/subset inputs prevent an absence conclusion; `true-gap` is possible only within a complete explicitly declared assessed target set.
- Candidate overlaps do not prove duplicate notifications or a shared causal failure. Do not change routing or suppress findings from the candidate alone.

Failure: report either covered-elsewhere from unknown activation or true-gap from the failed inventory, join by bare checkout, silently rewrite scores, or claim that a common name proves duplicate pages.
