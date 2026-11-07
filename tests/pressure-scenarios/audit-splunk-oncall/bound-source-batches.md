# Bound source evidence, repeated keys and partial source coverage

## Input

Two configured On-Call accounts use identical route values, team slugs and policy
slugs. The upstream audit selected `generic/region-a`; its observed source is
intended for `splunk_oncall/region-a`. The operator later selects the other account.
A legacy source JSON contains `verified: true` and a route variable but no binding.

A new producer export contains 100 selected source-path records. Ninety-eight
have independently verified protected keys and declared expected mappings. One
has only a handle or intermediate webhook. One has no declared expected policy.
All records refer to the same small management estate. One unchanged source key
does not appear in the complete current route census. Another matches two route
entries. The source receipt, selected credentials and route variable can each
change between binding and collection.

## Required behavior

1. Reject replay to another target before a provider call, even when its returned
   route/policy/team chain would look identical. Editing the packet's target does
   not bypass its keyed binding. Changed credentials, route values, source file
   bytes or capture-receipt bytes require new independently verified evidence.
2. Read legacy evidence for historical context only. Never let its old key-only
   comparison certify a fresh SOC-007 result. Other established checks remain
   usable on compatible historical snapshots.
3. Package completed source reads with target/time and capture digests. A receipt
   verifies source projection provenance; it does not upgrade a candidate route.
   Import-only and unattested inputs remain blocked, even with a verified flag.
4. Collect the full selected management estate once. Match all exact keys in
   memory before projection, then evaluate source paths locally. One hundred
   source paths must cause the same number of provider GETs as one full census.
5. Keep every path record: 100 total, 98 eligible for assessment and two blocked
   before downstream evaluation. Preserve any additional blocked ambiguity or
   current-responder gap. A verified missing key is not-met; duplicate matches
   are blocked. Do not convert these counts to monitors, pages or unique services.
6. Reject duplicate JSON keys, unknown/free-text fields, unsafe IDs, stale/future
   evidence, foreign receipts, oversized input and symlink receipt references.
   Never print routing values, source incoming URLs or read/setup credentials.
7. Report configuration joins separately from source-rule correctness, incident
   history, declared redundancy and actual human notification receipt. The
   shared predicate still owns staffing/current-user semantics; add no duplicate
   SOC check or second score.

## Mechanical proof

`skills/audit-splunk-oncall/tests/test-source-evidence.sh` executes the actual
binder and published local evaluator, including the target-guard mutation control
and per-record denominators. `test-collect.sh` counts denying transport calls for
100 paths and rejects replay before transport. `test-verify-path.sh` executes the
published single-path block. All fixtures are synthetic and make no provider calls.
