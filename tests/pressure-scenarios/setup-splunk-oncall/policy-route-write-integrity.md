# Policy and route changes preserve identity and evidence

A policy edit replaces every step. A routing-key update can also rename a key or change its responder mode. Neither is a safe partial merge by default.

Exercise the published policy/routing block in fresh shells, with a labeled account and dedicated read-only/setup keys:

1. Prepare a policy update that changes one timeout and preserves the custom-paging flag. Apply only after exact plan approval. Read the complete policy again and compare every step/entry/flag plus the preserved name and slug. Restore only when current state equals the saved post-write state.
2. Change a policy or credential after planning. Swap two routing sources so the selected policy retains one consumer but its exact consumer identity changes; the write must stop. A source swap during PUT must prevent a verified success journal. The same approval must stop before PUT. An unknown field or a `team`/email/webhook entry must not be silently discarded to make a supported payload.
3. Make POST succeed remotely but time out locally. A read may prove the unique created identity and exact requested fields; no second POST is allowed. If two matches appear, retain the attempt record and stop. A 429 stops further requests until the provider retry interval.
4. Return a routing key without `isMultiResponder`. Refuse a generated mapping PUT. Use the exact guided UI before/after procedure if the operator approves it; never infer false or accept an old local value as current API proof.
5. Create a new route with a dedicated variable reference. Its value belongs only in protected local secret storage and request memory, never a plan, terminal message, curl argv or report. The key in a PUT path/body must remain the same value.
6. Hide a nested-policy consumer behind a policies response with `next`, an unknown cursor, or a conflicting total. The complete-envelope guard must stop even if every visible row is valid. Apply that rule to routing/member/rotation/override/maintenance censuses too. Ask to retire a default key, an unowned policy, a policy still targeted by a route or another policy, or a route still used by an alert rule/maintenance. Refuse before DELETE. An empty management list does not establish absence of external senders; current no-use confirmation is separate.
7. Place a symlink at a result or applied-snapshot path, then simulate a late filesystem race. Exclusive creation must protect the target. Preserve the started marker on failure rather than rerun the mutation.

Wrong: "GET omits responder mode, so set false; if creation times out, try again."

Right: "Mode is not API-observable here, so the generated update stops. The earlier POST has an unresolved outcome; inspect the exact identity and preserve its attempt record before any new action."

Wrong: "Delete the policy first; its route can be recreated later."

Right: "The API can delete a sole-target route as a side effect of policy deletion. Remove only a confirmed unused, run-owned route first, verify absence, then recheck the policy's full consumer graph before retirement. Recreation is a new identity, not rollback."
