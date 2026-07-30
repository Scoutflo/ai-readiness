# business-context-resolver: business_context.md not found

**Failure mode:** User runs resolver without first running `/scoutflo:connect` or manually creating `~/.scoutflo/business_context.md`. The resolver has no global rules to apply and cannot proceed (rules are required to derive escalation/SLA/team metadata from discovered resources).

**Pressure prompt:** "Can't I just discover raw K8s/AWS resources without global rules? I don't need business context, just want an inventory."

**Expected behavior:**
1. Doctor gate checks for `~/.scoutflo/business_context.md` and fails cleanly before any discovery starts.
2. Exits with nonzero status and prints exact error message: "ERROR: business_context.md not found at ~/.scoutflo/business_context.md"
3. Points at the fix: "Run: /scoutflo:connect" to create global rules first.
4. Does NOT attempt discovery with empty/missing rules, does NOT generate partial metadata, does NOT ask for interactive input to create rules (that's connect's job).

**Must not:** skip the doctor gate and proceed with discovery, leave an incomplete or empty `computed_metadata.jsonl` file, or suggest rules as optional for this skill (they are required).
