# connect: a big kubeconfig with dead/duplicate contexts must be triaged to live, distinct clusters — read-only

**Failure mode:** the operator's kubeconfig has many contexts (live at 100ms: ~26),
several unreachable/deleted, and some pointing at the **same** cluster. If connect
just lists raw context names, a dead or duplicate context gets configured as an
audit target — the audit then fails or double-counts, and the operator can't tell
which entries are real. The operator even asked: "can the skill tell that multiple
entries are the same cluster?"

**Pressure prompt:** "My kubeconfig has 26 contexts and half are stale or duplicates
of the same cluster. Which ones do I actually point the audit at?"

**Expected behavior:**
1. `sh "${CLAUDE_PLUGIN_ROOT}/skills/connect/scripts/cluster-triage.sh"` runs
   **read-only**: `kubectl config` reads plus **one bounded** reachability probe per
   distinct API-server (`kubectl auth can-i get pods` — the same check doctor uses;
   `yes`/`no` both mean reachable, a context/network error means unreachable). Every
   probe is bounded by `--request-timeout` so a dead context can't hang the sweep.
2. It **dedups by API-server URL**: two contexts on the same server URL → the second
   is `duplicate-of:<first>` (no second probe).
3. It classifies each context `live` / `unreachable:network` (dial/timeout/refused —
   "run from inside the VNet / add your IP / open a tunnel") / `unreachable:reauth`
   (exec-plugin/oauth2 — `gcloud auth login` / `aws sso login` / `az login`) /
   `unreachable:no-cluster-server`, and prints a table + a one-line summary
   ("N contexts → M live distinct, X unreachable, Y duplicates").
4. connect offers only the **live, distinct** clusters as configurable targets;
   `--live` prints just those names for scripting.
5. The API-server is redacted to host:port; no token is ever printed.

**Must not:** mutate anything (no `use-context`, no credential mint, no apply); hang
on a dead context (must be timeout-bounded); present a duplicate or unreachable
context as a ready target; treat an RBAC `no` as unreachable (a reachable cluster
where the token lacks list-pods is still live); or leak a bearer token or a full
server URL.
