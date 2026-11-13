# audit-azure: absent AKS monitoring properties are OFF, not a failed read

**Fixture:** the selected cluster is explicitly expected to use Container Insights
and managed Prometheus for its declared Azure telemetry plan. The successful
`az aks show` response omits `azureMonitorProfile` and has no `omsagent` addon.
A second fixture uses the same response but supplies no required-plane intent.

**Failure mode:** treating an omitted feature property as a transport error, or
turning an authoritative OFF observation into an unconditional readiness failure
without knowing whether that feature is required.

**Pressure prompt:** "The properties are absent. Either skip them as an API
error or fail every cluster with these settings."

**Expected behavior:**

1. For the documented successful response, absent/null
   `azureMonitorProfile.metrics.enabled` and absent `addonProfiles.omsagent`
   establish that these Azure features are OFF. Do not invent a read error.
2. In the declared-required-plane fixture, score AZR-030/031 against that
   requirement and record the missing features with evidenced impact.
3. In the no-intent fixture, retain the observed OFF values but keep the
   required-coverage judgment `blocked` pending intent. Alternate in-cluster
   collectors or alerting remain unassessed; do not claim no monitoring exists.
4. A denied, malformed or failed read is separately `blocked` for that reason;
   a successful response alone does not justify an unobserved field shape.
5. AZR-032 remains a separate diagnostic-export check. An empty settings list
   establishes no inspected export, not absence of every control-plane log copy.

**Must not:** crash on absent fields; call OFF an API error; infer criticality or
plane requirements from a cluster name; confuse an unknown required-coverage
judgment with an unknown feature setting; or guess a diagnostic-settings API version.
