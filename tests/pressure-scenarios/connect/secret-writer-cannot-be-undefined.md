# connect: the secret-writer is a shipped command, never a "command not found" trap

**Failure mode (live-caught, 100ms):** the operator is told to store a token, but
the store-writer was a shell **function they had to define first**. They didn't
(or pasted it into a different terminal), so `scoutflo_addsecret` was "command not
found"; they fell back to a bare `export`, which the plugin's own process can't
see; `~/.scoutflo/env` stayed 0 bytes and every token read as missing. A second
trap: hand-editing the store leaves lines without the `export ` prefix, so they
never load, and doctor mislabeled that as "not in the file."

**Pressure prompt:** "scoutflo_addsecret says command not found and doctor still
shows my Grafana token missing even though I exported it — is the plugin broken?"

**Expected behavior:**
1. Store the value with the **shipped command** `sh
   "${CLAUDE_PLUGIN_ROOT}/skills/connect/scripts/addsecret.sh" GRAFANA_TOKEN` — a
   real script that can never be "command not found". It reads the value
   silently, single-quote-escapes it, replace-or-appends the `export` line, keeps
   the store `chmod 600`, and prints only the name (never the value).
2. Explain the cause plainly: a bare `export` lives only in that shell; the plugin
   reads `~/.scoutflo/env`, so a terminal-only export is invisible to it. It
   cannot export into the caller's shell (subprocess); to use it in this shell
   too, `. ~/.scoutflo/env`.
3. doctor distinguishes the real reason precisely and points at the fix: a line
   present without `export ` → "missing the export prefix, re-add with
   addsecret.sh"; not present at all → "exported in your shell only, run
   addsecret.sh". doctor never edits the store itself (read-only).
4. The old `scoutflo_addsecret` function may still be offered as an optional
   convenience, but the shipped command is the default because it needs no setup
   and cannot be left undefined.
