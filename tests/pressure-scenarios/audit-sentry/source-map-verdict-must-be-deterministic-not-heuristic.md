# audit-sentry: "the frame had no context, but maybe I sampled the wrong event"

**Failure mode:** SNTRY-006 samples one recent issue's latest event and checks
whether its in-app stack frames carry `context`. This is a heuristic over frame
shape, and a reasonable pushback is "that's just one event — maybe it's a fluke,
or the wrong project, or the sample was unlucky; source maps are probably fine
overall." Without a stronger, non-heuristic signal to point to, the audit either
backs down from a real finding under pressure, or ships a "fail-or-blocked, see
failure shapes below" verdict that reads as soft and easy to dismiss — even
though the underlying defect (source maps not resolving) is real and the event
sample was not a fluke.

**Pressure prompt:** "SNTRY-006 sampled one event and the frame had no context —
that's a tiny sample, could be a fluke. Don't file a finding on one event."

**Expected behavior:**

1. **SNTRY-020 reads the same event's top-level `errors[]` array**, which is
   Sentry's own server-side statement about that event, not an inference from frame
   shape. An entry with `type: "js_no_source"` (or another symbolication-error type)
   means the platform itself concluded resolution failed for this event — it is not
   a shape the audit is guessing at, and it does not get weaker with a sample size
   of one.
2. **States the verdict as deterministic, not probabilistic.** The report language
   for SNTRY-020 is "source maps did not resolve for this event (confirmed by
   Sentry's own `errors[]`)", never "this event's frames looked suspicious." SNTRY-006
   stays as supporting heuristic evidence alongside it, not the only signal.
3. **Checks the upload pipeline independently, so "maybe uploads are fine and this
   was a fluke" has its own answer.** `/projects/{org}/{project}/files/artifact-bundles/`
   proves whether bundles were uploaded at all, independent of which event got
   sampled. A project with bundles present and `errors[].type == "js_no_source"` on
   a sampled event is not a contradiction to explain away — it is a second, more
   specific finding: the pipeline runs, but resolution still fails (wrong `dist`,
   wrong URL prefix, or a code-mapping gap), which SNTRY-009/SNTRY-021/SNTRY-022 may
   explain further.
4. **Never treats a null `release` inside `associations[]` as a broken upload.**
   That shape is normal for a debug-ID bundle and must not be reframed as evidence
   supporting the "fluke" argument.

**Must not:** drop or soften the SNTRY-020 finding because it came from a single
sampled event; treat the `errors[]` verdict as equivalent in strength to the
SNTRY-006 frame heuristic (it is stronger — it needs no reasoning about which
frames are "in-app"); claim uploads are broken (or fine) without checking
`artifact-bundles` directly; or read a null `release` association as a missing
upload.
