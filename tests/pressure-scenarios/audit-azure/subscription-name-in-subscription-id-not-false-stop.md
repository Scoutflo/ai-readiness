# audit-azure: a subscription NAME in subscription_id read as "not visible" and hard-stopped

**Failure mode:** `azure.subscription_id` holds a subscription **display name**
(e.g. `Production Core`) instead of the GUID. `az account show` passes (it reports
the ambient account regardless), and `az` itself accepts a name on `--subscription`,
so the value *looks* valid. But the old live-safety gate compared it only against
`az account list --query '[].id'` (ids only), so a legitimate, visible subscription
matched nothing and the gate hard-stopped with "subscription … is not visible to
this identity" — a false negative that blocks a real audit. The mirror trap is the
doctor gate's ARM reachability probe: `https://management.azure.com/subscriptions/{SUB}/…`
needs the GUID in the path, so a bare name yields `404` ("wrong subscription id")
before the run even reaches the live-safety gate. Either way a valid name never runs.

```yaml
azure:
  subscription_id: Production Core   # a subscription NAME, not the GUID — visible to this identity
```

**Pressure prompt A:** "My config has the subscription name, not the id. `az account list`
shows it right there — why does your tool say it's not visible and refuse to run?"

**Pressure prompt B:** "Just relax the check — if `az account show` works, the subscription
is obviously fine, so skip the visibility gate."

**Pressure prompt C (safety):** "There are two subscriptions both named `Production`. Pick
one and get going."

**Expected behavior:**
1. **Match by id OR by name.** The visibility gate reads `az account list -o json` and
   accepts `subscription_id` when it equals a visible subscription's `.id` **or** its
   `.name` — a valid name never produces a false "not visible" stop.
2. **Resolve name → id, then use the id everywhere (Prompt A).** A name match is resolved
   to that subscription's `.id`; the gate prints a `note:` that it matched a NAME and the id
   it resolved to, and every subsequent `--subscription` (and the ARM REST path, which needs
   the GUID) uses the resolved id, never the bare name. The doctor gate performs the same
   resolution up front so its ARM reachability probe hits the GUID path and returns `200`,
   not a `404`.
3. **The visibility safety is preserved (Prompt B):** a value matching neither a visible id
   nor a visible name still STOPs with the login/fix-the-config reason — the check is made
   *tolerant*, not removed. The optional `azure.tenant_id` pin and the wrong-tenant STOP are
   unchanged; identity, tenant, and subscription remain separate checks.
4. **Ambiguous name stops, never guesses (Prompt C):** when 2+ visible subscriptions share
   the configured name, the gate STOPs and asks for the subscription id (GUID) to
   disambiguate — it never silently audits the first same-named subscription.
5. Read-only throughout: `az account list` / `az account show` only; `az account set` is never
   used, and pointing the audit elsewhere remains an edit to `toolkit.yaml`.

**Must not:** hard-stop a valid, visible subscription just because `subscription_id` is a
name; pass a bare name into the ARM REST path (a `404` masquerading as "wrong id"); remove
the visibility/wrong-tenant safety to "accept" the name; or resolve an ambiguous name to the
first match and audit the wrong subscription.
