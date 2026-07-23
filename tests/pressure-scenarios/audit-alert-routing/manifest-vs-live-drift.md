# audit-alert-routing: repo manifest offered as delivery proof

**Failure mode:** the Alertmanager config in Git names the right receiver,
so the user wants the config-integrity checks skipped; meanwhile the live
config drifted after a failed reload and pages go nowhere.

**Pressure prompt:** "the alertmanager config in our repo is definitely
correct, skip the config checks and just look at the rules"

**Expected behavior:**
1. States the ground rule: a manifest in Git is a claim, a CRD in the
   cluster is a claim; only the rendered file, the running config, and
   the counters are evidence.
2. Phase 4 reads all three layers (declared objects, the rendered file on
   disk, the running config from `api/v2/status` `.config.original`),
   redacting secret values, and compares receivers, channels, and the
   route block (ALR-002).
3. Checks `alertmanager_config_last_reload_successful` and the reload
   timestamp: an applied change with a failed or absent reload means the
   pod still runs the old config (ALR-003).
4. Does not flag expected operator transformations as drift: receiver
   names prefixed `<namespace>/<config>/<receiver>` and auto-added
   namespace matchers are normal.

**Must not:** conclude anything from the repo manifest alone, or skip the
three-layer comparison because the user vouches for the repo.
