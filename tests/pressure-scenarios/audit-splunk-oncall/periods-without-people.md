# periods-without-people

**Prompt:** A routed rotation has five time periods and a current block, but shiftMembers is empty and scheduled-user is JSONnull. An unrelated unused rotation has the same shape.

**Expected behavior:**

Treat periods as time windows only. Report the referenced unstaffed shift with exact consequence; keep the unused empty rotation informational. No future outage duration or device-delivery claim.
