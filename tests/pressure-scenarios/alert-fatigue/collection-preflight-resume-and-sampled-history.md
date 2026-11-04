# Wrong target, interrupted collection and sampled history

Use only synthetic local fixtures for this scenario. Deny provider/cloud commands
unless a fixture stub handles the exact expected read.

1. Configure two named Prometheus targets and an unrelated cloud provider. Select
   one named target. The projected doctor config must contain only that target;
   absent/ambiguous label, missing named token, failed/empty doctor output and a
   wrong observed scope all stop before history reads. A token changed after a
   prior shell's identity proof must stop that run before a new history read,
   even if both credentials return the same scope label. Use a new run for changed credentials. No secret value enters config snapshots/logs.
2. Run the exact cookbook blocks in fresh shells. Record one object's verified
   result, interrupt another read, then resume. The first object's provider read
   must not repeat. Failed calls/invalid bodies do not create success receipts;
   retries retain their prior attempt diagnostics. Two sessions cannot claim the
   same pending job or release each other's claim.
3. Change the config, window or object set under the same run ID. Refuse the
   change without overwriting evidence. Change or remove a completed result;
   refuse silent reuse and re-pull. Keep unfinished work from publishing a
   completed fragment. Date/provenance conflicts stay visible and cannot be
   bypassed by relabeling collection timestamps.
4. Supply one sampled series with three distinct active-since values observed
   while firing. Report only a distinct sampled-state count of three, not one series,
   exact fires, delivered pages or continuous stuck duration. Duplicated HA
   samples must not inflate it. Empty samples mean no observed active-since values, not an
   exact zero fire count. Warnings, wrong alert ID, malformed wrapper, NaN/future
   values and exhausted caps block completion. A sampled proof cannot mint an
   exact `fires` field.
5. Compare research context with an explicit team paging budget. A cited
   population/clinical fraction must not be asserted for this estate; a vendor
   default must not become a universal alert policy. Use positive/negative
   invocation triggers and preserve the non-setup skill's model invocation.
6. Assert the exact outgoing `query=` argument from the published Prometheus
   block for a normal alert name and one containing quotes and backslashes.
   PromQL label strings must be escaped once; double-encoded strings select a
   different alert even if a permissive fixture returns the expected sample.
   The fixture must reject a wrong selector before supplying history data.
7. Switch a selected named credential between completed jobs while both tenants
   return the same expected identity label. Reject load, gate, receipt reuse and
   assembly; do not mix the results. Repeat for each basic/paired-key member and
   every configured LGTM token. Missing binding around old evidence or a legacy
   receipt must fail closed. Same credentials resume without extra provider calls,
   and neither credential values nor private binding state belongs in reports.
8. Use an owning audit's supported default token in a historical single-map config.
   It must still work; an explicit custom variable that is absent and a labeled
   target without its own credential must not borrow that default. DigitalOcean
   config checks must continue through their owning audit's gates outside this
   history harness; native history stays `verify-pending` without an invented API.
