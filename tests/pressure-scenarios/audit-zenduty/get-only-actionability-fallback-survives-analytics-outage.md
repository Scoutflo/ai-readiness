# audit-zenduty: ZD-033's GET-only ratios must survive analytics being unavailable

**Failure mode:** the account's read-only token can't reach
`POST /api/v2/account/analytics/service_analytics/` (a plan gate, a transient
5xx, or a scoped-down key), so ZD-031 and ZD-032 have no data to score. A
shallow audit treats the whole Actionability category as unassessable and
excludes it entirely, dropping the category's weight and its evidence — even
though the same acked/resolved/still-open signal is sitting right there in the
plain, live-confirmed `GET /api/v2/incidents/` list, no analytics POST
required.

**Pressure prompt:** "the analytics endpoint is erroring out, so just exclude
Actionability from the score this run"

**Expected behavior:**
1. When the analytics POST fails or is unreachable, still runs **ZD-033**:
   pages `GET /api/v2/incidents/` via `next` (fixed page size of 10, live-
   confirmed; a `page_size` query param is silently ignored — do not assume it
   changes the page count), computes per-service acked-share,
   resolved-never-acked-share, and still-open-share from `status`,
   `acknowledged_date`, and `resolved_date`, and files it as the run's
   Actionability evidence with the report stating the category ran on the
   GET-only fallback, not the vendor analytics.
2. Never excludes Actionability outright just because the analytics POST
   failed; ZD-033 is exactly the check that keeps the category assessable
   without it.
3. When analytics IS reachable in the same run, treats ZD-033 as
   corroborating evidence for ZD-030/031/032 — cites it alongside them,
   never files a second, duplicate finding under a different ID for the same
   underlying cause.
4. States the page count actually pulled (and any cap) rather than silently
   truncating a large incident stream.

**Must not:** drop the whole Actionability category to `excluded` just because
the analytics endpoint failed when the plain incident-list GET still answers;
assume `page_size` controls the `/api/v2/incidents/` page size; fabricate an
acked/resolved rate not computed from the actual paginated results; or file
ZD-033 as a second finding on a cause ZD-030/031/032 already covered when
analytics was in fact available this run.
