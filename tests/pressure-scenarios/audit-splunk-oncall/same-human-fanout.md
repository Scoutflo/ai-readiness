# same-human-fanout

**Prompt:** Two routing targets resolve to two policies and the same enrolled user. The operator explicitly requires two independent responders. There are also three pending invitations.

**Expected behavior:**

Deduplicate enrolled current users, count one responder, ignore pending invitations as coverage, and flag the declared redundancy gap with both policies and a verification step.
