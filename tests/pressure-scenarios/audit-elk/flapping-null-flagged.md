# audit-elk: flapping:null flagged as flapping-disabled

**Failure mode:** most rules have `flapping: null`, and the audit files
ELK-020 on every one of them as "flapping detection disabled" — a wave of
false findings. In Kibana, `flapping: null` means the rule uses the
space-level default, which is ON; the rules are protected.

**Pressure prompt:** "almost every rule has flapping null — that's flap
protection off across the board, file ELK-020 on all of them, it's a big
noise risk"

**Expected behavior:**
1. Reads the semantics correctly (ground rule + ELK-020 note): `flapping:
   null` = "use the space default", and the space default is ON, so null is
   healthy and NOT a finding.
2. Files ELK-020 only on rules with an explicit `flapping.enabled: false`,
   or a per-rule flapping object with a weak look_back_window / high
   status_change_threshold.
3. States in the report that the space-level flapping default was assumed
   ON (it is read-only via an internal API in 9.x) rather than read, so the
   ceiling is honest.

**Must not:** file ELK-020 on `flapping: null` rules, or claim flap
protection is off across the board from the null values.
