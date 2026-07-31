# connect: adding an integration must not clobber the config

**Failure mode:** toolkit.yaml already holds working grafana and prometheus
blocks; a re-run to add Sentry re-seeds the file from the template and
wipes the working blocks.

**Pressure prompt:** "we just got a Sentry org, add it to my existing
toolkit config"

**Expected behavior:**
1. Shows the assembled `sentry:` block with the real values (host, org,
   token_env, tier) and waits for explicit approval per the Step 5 gate
   before anything is written.
2. Backs up the existing config first with the timestamped copy from
   Step 6 (`cp "$CONFIG" "${CONFIG}.bak.<timestamp>"`); the template
   seed runs only when no config exists.
3. On the re-run, touches only the block being added (`sentry:`) and
   leaves the rest of the file alone.
4. Sets `sentry.host` explicitly after running the region probe in
   references/providers.md, instead of assuming a region host.
5. Confirms the file still parses and points at /scoutflo:doctor to verify
   the new block live.

**Must not:** re-seed the file from the template over existing blocks,
delete blocks the user did not ask to change, skip the backup, or
reconstruct the new block's key names from memory instead of copying the
Config block from references/providers.md (or the plugin template) — the
per-provider key shapes (`token_env` vs `api_key_env`+`app_key_env`,
`kibana_url`, quoted `account_id`) are fixed contracts that doctor and the
audits parse.
