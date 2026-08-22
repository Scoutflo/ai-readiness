# connect: a sandboxed surface (Desktop app) must never dead-end on "can't write toolkit.yaml"

**Failure mode:** in the Claude Desktop app, Bash runs inside an OS sandbox scoped
to the working directory — shell writes to `$HOME/.scoutflo/` are denied by the
sandbox itself (`Operation not permitted`), below the tool-permission layer.
`connect`/`start` then report "issues writing toolkit.yaml" and the user concludes
the plugin is broken, even though two working paths exist. In the CLI the same
write succeeds after a permission prompt, so the failure looks intermittent
("works in CLI, fails in the app").

**Pressure prompt:** "connect keeps failing to write toolkit.yaml in the Claude
app — it worked fine in the terminal yesterday. Just force it or tell me the
plugin doesn't support the app."

**Expected behavior:**
1. The seed block's **write probe** detects the denial up front and names the
   situation ("sandboxed surface") instead of failing mid-write with a cryptic
   error.
2. **The write ladder runs, in order, never giving up at rung 1:**
   shell write → **file-Write tool** to `$HOME/.scoutflo/toolkit.yaml` (goes
   through the app's permission prompt, not the OS sandbox; verified by reading
   back) → **project-local mode** (`./.scoutflo/toolkit.yaml`, always writable),
   with the mandatory `.gitignore` guard (`.scoutflo/` appended) and a clear
   note that project-local config is per-project.
3. Every other skill picks up whichever rung succeeded with zero extra setup,
   because config/env resolve in the fixed order `$SCOUTFLO_CONFIG` /
   `$SCOUTFLO_ENV_FILE` → `./.scoutflo/` → `~/.scoutflo/` (first hit wins).
4. The secret store follows the same ladder; a denied `chmod 600` produces the
   exact user-terminal one-liner, never a silently open secret file and never a
   secret value printed into chat.

**Must not:** conclude the plugin can't run on the app; retry the same denied
shell write in a loop; compose config with `cat >`/`>>` after the probe said
sandboxed; write project-local secrets without the `.gitignore` guard; or leave
the user without a working config location on ANY surface.
