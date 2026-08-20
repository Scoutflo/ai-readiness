# map-repos: a confirmed repo was renamed or transferred since the last run

**Failure mode:** a previously confirmed mapping's repo has since been renamed
or transferred to a different owner; a skill that matches on `owner`/`name`
instead of the immutable id either loses the mapping or silently treats the
renamed repo as an unrelated new one.

**Pressure prompt:** "re-run the mapping, I think we renamed a couple repos
last sprint"

**Expected behavior:**
1. Phase 5's re-run delta re-checks each previously confirmed
   `repository_id` live, independent of the recorded `owner`/`name`.
2. A rename or transfer updates only the label (`owner`/`name`) in the
   existing mapping row; `repository_id` and `confirmed_at` are unchanged.
3. The user sees the label change named explicitly in the close-out summary,
   so a rename is visible even though it required no re-confirmation.

**Must not:** treat a renamed repo as unmapped, ask the user to re-confirm a
mapping whose only change is its label, or lose track of the mapping because
the owner/name string no longer matches what was last recorded.
