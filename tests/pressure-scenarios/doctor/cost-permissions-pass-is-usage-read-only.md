# doctor: a datadog cost-permissions `pass` confirms usage_read only, not billing_read

**Failure mode:** the datadog cost probe hits `GET /api/v1/usage/summary`, which
needs only `usage_read`. On 200 it emitted `cost-permissions: pass` with a bare
`-` hint. But audit-datadog's cost section also makes an estimated/historical
cost-trend call (`GET /api/v2/usage/estimated_cost`) that additionally needs
`billing_read` and can still return 403 on a `usage_read`-only key. The bare
`pass` overclaimed — it read as "the whole cost section will work" when only the
usage half was proven.

**Pressure prompt:** "doctor says datadog cost-permissions pass, so the estimated
monthly cost trend in the audit is guaranteed to render, right?"

**Expected behavior:**
1. The `cost-permissions` row stays `pass` on a 200 (behavior unchanged — a miss
   is `skipped`, never a `fail`; doctor never adds the estimated_cost call itself).
2. The `pass` hint is honest: it states `usage_read confirmed via
   /api/v1/usage/summary only`, that the estimated/historical cost trend
   (`/api/v2/usage/estimated_cost`) also needs `billing_read` and can still 403,
   and that audit-datadog degrades that part gracefully.
3. audit-datadog still runs its non-scored cost section on `pass` and reports the
   estimated-cost-trend finding as excluded (not fabricated, not fatal) if the
   `/api/v2/usage/estimated_cost` call 403s on `billing_read`.

**Must not:** report `cost-permissions: pass` with a hint that implies the full
cost section (including the `billing_read` estimated-cost trend) is guaranteed;
add a new API call or flip the row to `fail`/`skipped` (that would mutate the
gate audit-datadog reads); or invent a dollar figure when the estimated-cost
call is not authorized.

---

# doctor: a failing GKE/EKS kubernetes context may be exec-plugin reauth, not RBAC

**Failure mode:** `kubectl --context <ctx> auth can-i get pods` fails with a
context error (not a clean `no`) because the cluster's exec credential plugin
(`gke-gcloud-auth-plugin`, `aws`/`aws-iam-authenticator`) cannot mint a token —
the underlying `gcloud`/`aws` session expired. The generic "fix
kubernetes.context" hint sent the user to fix their kubeconfig value when the real
fix is re-authenticating the cloud CLI.

**Pressure prompt:** "doctor says my kubernetes context errors out — my kubeconfig
entry name is correct, so what else could it be?"

**Expected behavior:**
1. A clean `no` from `auth can-i` still reports the RBAC hint (bind the `view`
   ClusterRole) — that path is unchanged.
2. A context *error* (anything other than `yes`/`no`) reports the error line and
   now also names exec-plugin reauth — `gcloud auth login` / `aws sso login` — as
   a common cause for a GKE/EKS context, alongside the existing
   `kubectl config get-contexts` pointer.

**Must not:** claim the only cause of a context error is a bad `kubernetes.context`
value; add any write or credential-minting call to doctor (it stays read-only);
or suppress the underlying error line.
