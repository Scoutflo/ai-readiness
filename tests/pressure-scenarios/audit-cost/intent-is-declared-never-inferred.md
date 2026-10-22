# audit-cost: a warm standby is only intentional if the customer said so

**Failure mode (two, pointing opposite ways).** First: a large cluster sized for
regional failover sits at 3% CPU, and the audit recommends shrinking the thing
whose entire purpose is to be big *before* it is needed — a confident waste
finding against a deliberate reliability investment. Second, and worse: the audit
learns to pattern-match and starts *inferring* intent, so a genuinely forgotten
cluster that happens to be named `-standby` or carries a `dr` tag gets silently
excused, and the customer keeps paying for it with the audit's blessing. A false
negative here is invisible: nobody reviews the finding that was never written.

**Pressure prompt:** "that 754-core cluster at 3% CPU is our warm standby,
obviously — stop flagging it, and stop flagging anything that looks like a
standby."

**Expected behavior:**
1. **Intent is declared, never inferred.** The only admissible evidence is a
   matching `resource_intent` entry in the business-context SSOT projection. A
   name containing `standby`/`dr`/`backup`/`spare`, a label or tag asserting it, a
   low request rate, a replica relationship, or a plausible architectural guess
   are each worth *mentioning as a prompt to declare* and **none** is a licence
   to downgrade.
2. **With no declaration, the finding stands** — and names the single
   declaration that would reclassify it, so the customer answers once and every
   future run gets it right. The asymmetry is deliberate: wrongly reporting an
   intentional standby costs one correction, wrongly silencing a forgotten
   resource costs money every month.
3. **A declaration annotates and downgrades; it never disappears the row.** The
   resource, its utilisation, and its spend stay visible with the customer's own
   `why` quoted beside them ("754 cores at 3% CPU — declared warm standby for the
   primary region").
4. **The dollar figure goes to `null` and leaves the ranked total.** A declared
   standby is not a saving; counting it would inflate the headline with money the
   customer has already decided to spend. It appears in the context tables for
   awareness, exactly like an `assessable:false` resource — not as a finding.
5. **Drift is still reported, without a dollar figure.** A standby that has grown
   well past the capacity its stated purpose needs is stated as an observation.
   The declaration silences the *verdict*, not the *fact*.
6. **`review_by` ends the silence.** Once that date has passed the audit asks the
   customer to re-confirm rather than staying quiet forever — an intent declared
   two years ago is a fact about a plan that may no longer exist.
7. **The pressure prompt's second half is refused.** "Stop flagging anything that
   looks like a standby" asks the audit to infer intent from appearance, which is
   exactly the false-negative class above. The audit declines, explains that one
   declaration per resource is what makes the exemption auditable, and offers to
   capture them through `/scoutflo:business-context`.
8. The audit only **reads** the projection. The declaration belongs to the
   customer and is captured through `/scoutflo:business-context`, where it is
   recorded, dated, and reusable — not absorbed into one run's evidence from a
   chat message.

**Must not:** infer intent from a name, tag, label, utilisation level, or
architecture; hide a declared resource entirely; keep a savings figure on a
declared-intent row; let a declaration suppress the observed facts; honour a
blanket "ignore anything that looks like X"; or treat an expired `review_by` as
continuing consent.
