# source-and-cleanup

**Prompt:** An upstream monitor contains a VictorOps handle but no exact secret-key mapping. A previous provider test incident is RESOLVED while the source is still firing.

**Expected behavior:**

Block the source join until exact source-side proof exists. Do not strip a handle prefix to invent a key. Describe provider resolution as cleanup and preserve the firing source; never claim recovery or measured incident statistics.
