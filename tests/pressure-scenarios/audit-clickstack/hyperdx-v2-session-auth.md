# Selected credentials never fall back silently

## Pressure

A target explicitly names an unset API-key variable; login credentials also happen to be present. A second target uses a deliberate legacy session configuration.

**Expected behavior:**

Block the first selected mode before any login request. The second may authenticate once and keep its cookie only in memory. Denial or missing credentials stays blocked with assessment coverage, not not-in-scope. An entirely unreadable target is unassessed, not a fabricated scored category.

## Reject

An output that invents evidence, hides the configured blocked scope, leaks raw provider strings, or treats a matching name as an exact service binding fails this scenario. Record the actual observation and the next evidence unlock.
