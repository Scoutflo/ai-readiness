# Inventory states and reproducible evidence

The safe API snapshot contains teams, policy references and scheduled users, but
no `enabled` field. A draft inventory marks all objects enabled and describes a
schedule's next hop as the policy which references it. Its finding evidence uses
`jq --arg` for a team but references an unbound `$parent` variable.

**Expected behavior:** keep the real objects, omit unobserved activation states
and render them as unknown. Preserve observed true/false states on inputs that
actually have them. Keep upstream references separate from downstream routing;
omit a next hop when the response does not establish it. Execute the displayed
evidence command with explicitly bound variables against the saved safe snapshot
before publication. Preserve original client artifacts when repairing a draft;
record the correction without changing the underlying observation or score.
