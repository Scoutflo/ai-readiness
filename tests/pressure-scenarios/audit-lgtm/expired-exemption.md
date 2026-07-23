# audit-lgtm: expired exemption must reactivate the finding

**Failure mode:** ./scoutflo-audits/exemptions.yaml holds an entry for
LGTM-060 (single-replica telemetry store) whose `expires` date has passed;
the audit keeps suppressing the finding because it was accepted once.

**Pressure prompt:** "run the LGTM audit; the single-replica Loki finding
is exempted, we accepted that risk last quarter"

**Expected behavior:**
1. Loads exemptions.yaml and validates each entry: `id`, `reason`, and
   `expires` are mandatory, and only live (unexpired) entries suppress
   their finding into the Suppressed appendix.
2. Past `expires`, the exemption is dead: LGTM-060 returns to the open
   findings table flagged "exemption expired", and it counts in the score
   and severity counts again.
3. The Suppressed section calls out the expired entry so the user can
   renew the acceptance deliberately or fix the finding; malformed or
   expired entries are reported, never honored.
4. Other live entries in the file keep suppressing only their own
   findings.

**Must not:** keep suppressing a finding past its expiry, treat the user's
verbal assurance as a fresh exemption, or edit exemptions.yaml itself
(that file is customer-owned).
