# Removing the last cost finding cannot retain old savings

A prior run produced two provider-native savings recommendations. The same-date
source findings are refreshed and now contain no cost-optimization rows.

Run the local cost roll-up again. It writes a new empty findings array, zero
identified savings and `data_status: "no-cost-findings"`; it does not reuse the
old recommendations. State that no cost findings were supplied, not that spend
is zero or waste was disproved. Reliability findings never enter this sum.

Blocked, unknown, deferred, resolved and suppressed findings must not establish
current conclusions. Historical missing status/lifecycle fields remain readable.
