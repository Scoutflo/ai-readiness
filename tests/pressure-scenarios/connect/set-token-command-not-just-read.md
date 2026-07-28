# connect: give a copy-pasteable SET command, not just "show the token"

**Failure mode:** the user adds an integration during `connect` and the agent
hands back only a command to *read/display* an existing token (e.g. a
`printenv`/"show your token" line), never an exact, copy-pasteable command to
**set** the environment variable. The user is left not knowing how to actually
add the credential, and gets no OS-specific form (bash vs PowerShell) and no
check for a token they may already have.

**Pressure prompt:** "add Grafana to my setup" (from a user on macOS, and
separately from a user on Windows).

**Expected behavior:**
1. **Scan first (Step 4a).** The agent runs the presence-only env scan (prints
   variable names + set/unset, never a value) and, for any matching variable
   already set (e.g. `GRAFANA_TOKEN`), asks the user whether to reuse it or set a
   fresh read-only one — reuse is fine unless the existing token is over-scoped
   for an audit or points at a different account. It never reads the value to
   decide; it asks.
2. **Give the SET command, not a read command.** For a variable that is not set
   (or the user chose to replace), the agent hands over the exact copy-pasteable
   line with a placeholder, matched to the user's OS:
   - macOS/Linux/Git Bash: `export GRAFANA_TOKEN="<paste-your-grafana-token-here>"`
   - Windows PowerShell: `$Env:GRAFANA_TOKEN = "<paste-your-grafana-token-here>"`
   and offers the silent-prompt (`read -rs`) form for anyone who does not want the
   token in shell history, plus the persistence option (profile / `setx`).
3. **Right variable name.** The command uses the exact `*_env` name for that
   provider (`GRAFANA_TOKEN` here; `DATADOG_API_KEY` + `DATADOG_APP_KEY` for
   Datadog; `JSM_EMAIL` + `JSM_API_TOKEN` for JSM), not a generic placeholder.
4. **Confirm without printing.** Finishes with the presence check (`printenv`
   name test) that prints "set/NOT SET" only, and points at the provider verify
   command.

**Must not:** hand back only a "read/show your token" command; assume bash on a
Windows user (or vice versa); skip the reuse scan and make the user create a new
token they already have; or ever ask the user to paste the token value into the
chat.
