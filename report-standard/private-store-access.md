# Reaching a private / VPN-only observability store (read-only)

Shared recipe for every store-based audit (`audit-grafana`, `audit-lgtm`,
`audit-prometheus`, `audit-alertmanager`, `audit-clickstack`, `audit-signoz`).
When a store's HTTP endpoint is not reachable from the machine running the
plugin — it lives inside a cluster with no public ingress, or behind a VPN whose
tunnel covers only part of the network, or on a network with overlapping CIDRs —
this is how you give the audit a read-only path to it. Nothing here changes a
live resource: a port-forward or an `ssh -L` tunnel is a **local read-only
proxy**, and the plugin rides an access path you already have. Scoutflo stores no
credential and opens no network path of its own; if none of the bridges below is
available, the store is honestly skipped, not guessed at.

Every audit reads its store URL from `~/.scoutflo/toolkit.yaml` (the `*_url` /
`.url` keys — nothing is hardcoded), so the whole recipe is: **open a read-only
bridge, then point that store's URL at `http://127.0.0.1:<local-port>`.**

## A — the store runs inside your cluster (kubectl port-forward)

Most in-cluster stores (Grafana, VictoriaMetrics, Loki/Tempo/Mimir, Prometheus,
Alertmanager, ClickHouse/HyperDX) have no external ingress. Forward the in-cluster
Service to a local port — this rides the same kubeconfig the cluster audit uses,
including a private or JIT-tunnelled cluster (see
[audit-kubernetes: Accessing private or JIT-tunnelled clusters](../skills/audit-kubernetes/SKILL.md)):

```bash
# kubectl assigns a free local port and prints it; leave this running in its own terminal
kubectl port-forward -n <namespace> svc/<store-service> :<remote-port>
```

Then set that store's URL in `~/.scoutflo/toolkit.yaml` to the printed local
port, e.g. `victoriametrics_url: "http://127.0.0.1:<local-port>"`, and run the
audit. When you close the port-forward the audit simply loses access and says so.

## B — the store is behind a VPN / bastion but not in the cluster (ssh -L)

When the store is a plain host reachable only from inside the corporate network
(a managed Grafana, a VM appliance) and the VPN tunnel on your machine does not
cover it — the classic overlapping-CIDR / partial-tunnel case — forward it
through a jump box that *can* see it:

```bash
# local :<local-port>  ->  <store-host>:<store-port>  as seen from <bastion>
ssh -L <local-port>:<store-host>:<store-port> <bastion-host>
```

Then point the store's URL at `http://127.0.0.1:<local-port>` and run the audit.
This is the `ssh -L` path already listed for clusters; it works identically for a
bare HTTP store.

## C — run the audit from inside the network

If you have a workstation, bastion, or CI runner that already sits inside the
network, run the audit there with the store's internal URL directly — no tunnel
needed. The plugin is markdown + shell; it runs wherever `claude` and the store's
URL resolve.

## The honest degrade

`/scoutflo:doctor` probes every configured store and, for each one it cannot
reach, prints this bridge as the one unlock (in-cluster → port-forward;
VPN-only host → `ssh -L`). A store you genuinely cannot reach by A, B, or C is
reported unreachable and left out of the audit — the plugin never fabricates a
network path or a finding for a store it could not read.

## Which key to point at `127.0.0.1`

| Store | Key in `toolkit.yaml` |
| --- | --- |
| Grafana | `grafana.url` |
| Prometheus | `prometheus.url` |
| Alertmanager | `alertmanager.url` (or the lgtm stack's `alertmanager_url`) |
| LGTM stack | `loki_url` / `tempo_url` / `mimir_url` / `victoriametrics_url` / `vmalert_url` (list entry), or `loki.url` etc. (single block) |
| ClickStack | `clickhouse_url` / `hyperdx_url` |
| SigNoz | `signoz.url` |

All bridges are read-only. Never disable TLS verification to reach a store; if it
uses an internal CA, trust the CA locally instead.
