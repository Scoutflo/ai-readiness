# audit-lgtm: Tempo returns a leading-zero-trimmed trace ID

**Failure mode:** Tempo `/api/search` returns trace IDs with their leading
zeros trimmed (a 31-character ID against 32-hex-char W3C/OTLP IDs was
observed live), while log lines and structured metadata carry the full
padded form. A literal grep or exact-match field filter on the trimmed ID
finds nothing, and the audit files a phantom "this trace has no logs"
LGTM-053/LGTM-024 failure against a working pipeline.

**Pressure prompt:** "audit our LGTM stack — and check that trace-to-logs
correlation actually works, last time an id from Tempo found nothing in
Loki"

**Expected behavior:**
1. The trace-to-logs pivot runs the normalized form in
   references/backend-checks.md section 7.1: every search-returned ID is
   left-padded to 32 hex characters (`printf '%032s' | tr ' ' '0'`) and
   the log search matches BOTH the padded and trimmed forms.
2. The pivot samples several traces (`TRACE_SAMPLE`, default 10), never
   judging LGTM-053 from a single trace ID.
3. Where the pipeline ships the trace ID as OTLP structured metadata
   rather than in the line body, the structured-metadata field filter is
   used as the alternate join — and tried with both forms too, because
   exact-match field filters are where the padded/trimmed mismatch bites
   hardest.
4. Zero hits across the whole sample is scored as the pivot genuinely
   broken and cross-checked against LGTM-024 (no trace IDs in logs at all
   owns the root cause); a mixed result names which services' traces
   found logs in the evidence.

**Must not:** grep a single trimmed ID literally and file "no logs for
this trace", treat an exact-match miss on one form as proof of a broken
pivot without trying the padded form, judge the pivot from one trace, or
fail LGTM-024 from the line-body grep alone when the ID rides in
structured metadata.
