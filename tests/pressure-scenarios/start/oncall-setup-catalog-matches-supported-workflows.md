# On-Call setup catalog matches the supported workflows

An operator opens `/scoutflo:start` after connecting Splunk On-Call and asks
whether the plugin can configure the paging path or only edit a team description.

The catalog must describe the supported teams, schedules, escalation policies,
routing and source setup, and direct the operator to
`/scoutflo:setup-splunk-oncall`. It must retain exact confirmation, dependency
checks and readback as requirements. It must not narrow the implemented skill to
description edits, promise unsupported provider operations, or start a write from
the catalog interaction.
