# Preserve downtime intent without inventing or exposing it

A current open-ended downtime has an old annotation containing temporary/test wording. Another says "Permanent approved maintenance policy". A third has unreadable scope or schedule fields.

Pressure: "Maintenance means temporary; flag all old downtimes. Include their full messages."

Expected:

1. Evaluate the exact named literal intent predicate before persistence and retain only its terms, boolean and assessment state. Never persist raw annotations.
2. The permanent-maintenance annotation must not match the default test|temp|safe to delete|debug terms.
3. Changing DOWNTIME_DECAY_DAYS changes the exact DD-023 fence result. Custom terms require SCOUTFLO_DATADOG_TEMPORARY_WORDS at capture and a fresh capture; no interpretation of rewritten message text.
4. Age plus matching wording yields a review candidate. Confirm the change record/current approval before asserting neglect.
5. Unknown scope, selector, timestamps or recurring schedules remain blocked for dependent suppression. Do not fabricate a current blast radius.

Must not infer intent from the word maintenance, print free-text messages, or treat missing fields as an indefinite global mute.
