# Kubernetes live-evidence probe catalog + failure taxonomy

The read-only probes in [`../lib/live-evidence.sh`](../lib/live-evidence.sh) and the
decision tree a caller (rca) uses to turn their output into a *named* cause — or
an honest gap — without ever inventing one. Every probe is `kubectl get/describe/
list/logs/events` only, pins `--context` explicitly, and is bounded by
`--request-timeout`; the read-only guarantee is enforced by
`ci/liveness-readonly-check.sh`.

## Probe catalog

| Function | kubectl (read-only) | Signal it yields |
| --- | --- | --- |
| `probe_pod_status <ctx> <ns> <pod>` | `get pod -o json` | phase; per-container `restartCount`, `ready`, `state.waiting.reason`, `lastState.terminated.reason`+`exitCode`+`finishedAt`; pod conditions |
| `probe_events <ctx> <ns> <obj>` | `get events --field-selector …,type=Warning --sort-by=.lastTimestamp` | recent Warning events (FailedScheduling, BackOff, Unhealthy, Failed) — newest last, bounded |
| `probe_rollout <ctx> <ns> <deploy>` | `get deploy -o json` | desired/ready/updated/unavailable replicas + rollout conditions |
| `probe_owner <ctx> <ns> <pod>` | `get pod`/`get rs -o json` | ownership chain (pod → ReplicaSet → Deployment) for **identity resolution only** |
| `probe_logs_previous <ctx> <ns> <pod> [container] [tail]` | `logs --previous --tail=N` | the dead container's last logs, **redacted** and tail-capped (never raw, never persisted) |
| `le_can_probe <ctx>` | `config get-contexts`, `auth can-i get pods` | degrade-not-block readiness: is a live probe possible on this context at all |

## Failure taxonomy — name a cause ONLY when its specific field is present

This is how "never invent a cause" extends to live evidence. Each branch may be
stated as a **cause** only when the exact observed field below is present. A bare
symptom (e.g. `restartCount > 0` alone) is a **symptom**, never a verdict — a pod
restarting during a normal rollout is not a crash. A blocked/RBAC-denied/`null`
probe is a **gap** (`verdict=unknown`), never silently read as healthy.

| Observed field (from a probe) | Named cause | Notes / do-not-confuse |
| --- | --- | --- |
| `state.waiting.reason = CrashLoopBackOff` **and** a `lastState.terminated` with non-zero `exitCode` | Container is crash-looping; cite the exit code + the previous-log tail | CrashLoopBackOff is the *backoff*, not the reason — always pair it with the terminated reason/exit code |
| `lastState.terminated.reason = OOMKilled` (typically `exitCode = 137`) | Killed for exceeding its memory limit | Correlate with a `[report]` "no/low memory limit" posture finding → cited root cause |
| `state.waiting.reason = ImagePullBackOff` / `ErrImagePull` | Image cannot be pulled (bad tag, private registry, missing pull secret) | The event message names which; cite it |
| `state.waiting.reason = CreateContainerConfigError` | Missing ConfigMap/Secret ref or bad env/volume mount | Names the missing object in the event; do **not** read the Secret's value to "check" |
| Event `reason = Unhealthy` (liveness/readiness probe failed) | Probe failing — app up but not serving, or restart storm from a too-tight liveness probe | Distinguish readiness (not serving) from liveness (being killed) |
| phase `Pending` + event `reason = FailedScheduling` | Unschedulable; cite the scheduler message (insufficient cpu/mem, taints, no node) | Not a crash — a scheduling gap |
| `restartCount` high but reason is a normal rollout / no terminated error | **Symptom only** — report the count, do not name a cause | The benign-rollout trap; needs a terminated reason or event to become a cause |
| probe returned nothing / RBAC-denied / timeout | **Gap** (`verdict=unknown`) — record what was attempted and why it failed | Never "healthy"; list a re-probe with wider access as the next step |

## Provenance + redaction rules for callers

- Tag every fact from a probe `[live@<ISO8601-now>]`; tag report-derived facts
  `[report@<run_date>]`. When a live probe contradicts a report, live wins and the
  delta is stated (`report showed restartCount 0 @<date>; live now shows 42 [live@now]`).
- Log slices are already redacted by the lib. Never write a raw log line into a
  report, findings file, or Slack brief; summarize and cite the redacted slice.
- `probe_owner` output is **identity**, used to resolve which workload to probe.
  It is never a candidate cause (a service being *deployed as* a workload does not
  make the workload an upstream dependency).
