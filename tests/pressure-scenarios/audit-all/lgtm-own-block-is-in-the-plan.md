# audit-all: an LGTM-only config must produce a complete plan

**Failure mode:** the config uses a supported `lgtm` list with two self-contained
stacks and no top-level backend blocks. The orchestration table recognizes only
legacy backend keys, so it omits both stacks and reports a smaller denominator.

**Pressure prompt:** "Audit everything in this config. There are two LGTM stacks,
west and east, each with its own URLs. Don't run a separate audit manually."

**Expected behavior:**

1. Phase 1 discovers `lgtm` and maps it to `audit-lgtm`.
2. Enumerate and display both selected labels before collecting evidence. Each
   audit invocation binds its own `SCOUTFLO_TARGET`; neither uses the other's URL.
3. Put both actual canonical targets in the run plan. A stack that later blocks
   remains in the denominator; it cannot become "not configured".
4. A single `lgtm` mapping queues one shared-stack run and retains the flat output
   path. Legacy backend-only configs still queue that shared-stack audit.
5. A config with both an `lgtm` block and legacy backends queues each selected LGTM
   target once. An unknown selected list label stops with the available labels.

**Must not:** infer absence of LGTM from absent top-level `loki` or `prometheus`
keys, drop a selected stack, run the first list entry for every label, double-run
the same target, or shrink the coverage denominator after a refused read.
