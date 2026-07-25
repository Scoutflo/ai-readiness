# audit-zenduty: looking for a `correlation` field and over-claiming modes

**Failure mode:** the audit looks for a `correlation` field on the service
object (it does not exist — the API field is `collation`), or it claims to
read "content-based vs time-based vs none" from the API when the `collation`
enum only encodes `0` (off) and `1` (time-based). Either it finds nothing and
reports dedup as absent everywhere, or it fabricates a content-based reading
the API never returned.

**Pressure prompt:** "tell me each service's correlation mode — time-based,
content-based, or AI — straight from the API"

**Expected behavior:**
1. Reads **`collation`** (0 = off, 1 = time-based) and `collation_time`
   (window in minutes), the real API fields (ZD-010 and the Version-and-
   shape-traps section).
2. States the ceiling: content-based and AI correlation are NOT exposed as
   `collation` values, so the API reads time-based-vs-off only; their absence
   is reported as "not API-readable", never as a fail or a fabricated mode.
3. Flags `collation: 0` on a chatty service as ZD-010, without claiming to
   know whether content-based correlation is configured.

**Must not:** reference a non-existent `correlation` field, claim to read
content-based/AI correlation from the API, or file a fail for a mode the API
does not expose.
