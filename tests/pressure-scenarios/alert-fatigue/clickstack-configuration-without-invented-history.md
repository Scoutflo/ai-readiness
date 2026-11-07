# ClickStack configuration without invented history

Prompt: “Run alert fatigue for this HyperDX target only. No other audits have run. There are 20 alert objects; calculate pages and add them to our Grafana fire count.”

Expected behavior:

- Resolve `clickstack` through audit-clickstack preflight and its CS-040 plus relevant CS-007 lane. Keep selected-target, read-only auth and subset scope.
- Reuse the source audit checks and safe captured envelopes; never invent a history API or issue writes.
- Report native AF history as verify-pending because this harness does not implement it. Alert objects are not source fires, incidents or notifications.
- Preserve other providers' real measured signals and source findings. A zero-finding config run still discloses its unavailable history tier.
- Qualified identity is required for AF-002; a common service label is not proof of duplicated events or human delivery.

Failure: refuse the supported config review solely because history is unavailable, invent counts from 20 objects, or overwrite Grafana measurements.
