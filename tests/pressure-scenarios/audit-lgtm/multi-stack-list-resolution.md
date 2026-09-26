# audit-lgtm: a multi-stack `lgtm:` list audits each cluster/env, nested per label — a single map stays flat

**Failure mode:** a customer runs their LGTM/VictoriaMetrics stores across several
clusters or environments (a prod stack and a pre-prod stack). Before IMP-003 the
only shape was a single `lgtm:` map + one set of top-level store blocks, so they
had to hand-split into one `toolkit-<env>.yaml` per stack and run the audit N times
(the live 100ms friction). If the audit silently audited only the first stack, or
overwrote one stack's report with the next, or `doctor` spuriously failed the
multi-stack config, the estate would look half-covered or broken.

**Pressure prompt:** "Our loki/tempo/metrics live on two different clusters — prod
and pre-prod. Can one `/scoutflo:audit-lgtm` run cover both, with a separate report
per environment, without me maintaining two config files?"

**Setup shape (`lgtm:` as a LIST of self-contained flat stack entries):**
```yaml
lgtm:
  - label: prod
    runtime_mode: kubernetes
    kubernetes_context: prod-cluster
    loki_url: https://loki.prod.example.com
    victoriametrics_url: https://vm.prod.example.com
  - label: preprod
    runtime_mode: kubernetes
    kubernetes_context: preprod-cluster
    loki_url: https://loki.preprod.example.com
```

**Expected behavior:**
1. The audit **iterates every stack**: enumerate with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> lgtm labels`, then run the full sequence once per stack with `SCOUTFLO_TARGET=<label>`. Phase 0/2 resolve **that stack's** `runtime_mode`, `kubernetes_context`, `monitoring_namespace`, and store URLs (flat `loki_url`/`tempo_url`/… keys) via the enumerator — never the top-level blocks, never an ambient default.
2. Output **nests per stack**: `LG_SEG=lgtm/<label>`, so `prod` writes `scoutflo-audits/lgtm/prod/<date>/{findings.json,report.md,inventory.json}` and its own `lgtm/prod/history.jsonl`, and `preprod` writes `lgtm/preprod/<date>/…` — one never overwrites the other, and per-stack trend history stays intact.
3. **Single `lgtm:` map (or absent) is byte-identical to before:** `LG_SEG=lgtm`, flat `lgtm/<date>/`, `runtime_mode` from the `lgtm` map, context from the top-level `kubernetes:` block, store URLs from the top-level `loki:`/`tempo:`/… blocks. Zero migration.
4. **Fail closed per stack:** a stack entry with `runtime_mode: kubernetes` but no `kubernetes_context` stops with a clear per-stack error naming the label — it does not silently skip or fall back to another stack's context.
5. `/scoutflo:doctor` on a multi-stack config emits **per-stack** rows (`lgtm:<label>` runtime-mode + per-store reachability), never the spurious "lgtm.runtime_mode is required" fail that a naive `.lgtm.runtime_mode` read would produce on a list.
6. `grafana:` stays a single shared top-level block; the top-level `prometheus:`/`alertmanager:` blocks remain for `/scoutflo:audit-prometheus` and `/scoutflo:audit-alertmanager` (single-target).

**Must not:** audit only the first stack when a list is configured; write all stacks to a single flat `lgtm/<date>/` (collision/overwrite); read a top-level `loki:`/`kubernetes:` block for a list entry; change the single-block behavior in any way; treat a list `lgtm:` as an error in `doctor` or the audit; or invent a stack that is not in the config. A bogus `SCOUTFLO_TARGET` that matches no label warns and audits the first stack (labels stay self-consistent), rather than failing opaquely.
