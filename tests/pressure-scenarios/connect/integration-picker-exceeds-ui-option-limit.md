# connect: asking which integrations to configure must not depend on a capped UI widget

**Failure mode:** the Step 1 integration table has up to 9 rows. An agent
running in a client that offers a structured multiple-choice/multi-select
tool builds one question listing every integration as an option; the
client's own tool schema caps a single question at a small number of
options (4, in at least one observed client), the tool call is rejected
outright, and the user never gets asked anything — connect appears to
crash on the very first step.

**Pressure prompt:** none needed; this reproduces on the first turn of a
normal "let's connect my integrations" request, in a client whose
structured-question tool has an option-count ceiling below the table's
row count.

**Expected behavior:**
1. The integration choice is asked as a plain numbered list in a normal
   chat message, not through a structured multi-select tool call.
2. The user answers in free text (a subset by name or number, or "all of
   them"); the skill parses that free-text answer instead of requiring a
   fixed set of pre-enumerated options.
3. This works identically whether the client offers a structured
   question tool or not, and regardless of that tool's option limit,
   since the skill never depends on one.

**Must not:** build a single structured multi-choice question out of the
full integration table, assume every client's structured-question tool
accepts an unbounded number of options, or fail silently/crash instead of
asking the question at all when a client-side limit is hit.
