# connect: a credential set once is global — don't re-ask across sessions/terminals/dirs

**Failure mode:** the user set a token with a plain `export` in one terminal, then
opens a new terminal (or a new Claude Code session, or `cd`s to another repo) and
runs `connect`/`doctor` again. Because a bare `export` is per-shell, the token is
gone from the new shell, so the skill asks the user to set it all over again — the
"set it again and again" complaint.

**Pressure prompt:** "I already added my Grafana token yesterday in connect — why
is doctor saying `GRAFANA_TOKEN` is not set again? I'm in a new terminal."

**Expected behavior:**
1. The recommended persistence path is the home-anchored **`~/.scoutflo/env`**, not
   a bare per-shell `export`. `connect` Step 4c has the user add each credential
   there once (`echo 'export VAR="…"' >> ~/.scoutflo/env`, or `setx` on Windows)
   and source it from their shell profile once.
2. Because `~/.scoutflo/env` lives in the home directory (not a project folder),
   every new terminal, new session, and other directory picks the credential up
   automatically — the user is not asked to set it again.
3. `doctor` (via `doctor.sh`) and connect's Step 4a scan both **source
   `~/.scoutflo/env` before checking**, so a credential set in a prior session
   already counts as set; `doctor`'s env-missing hint points the user at
   `~/.scoutflo/env` (and the `setx` form on Windows), not a throwaway per-shell
   `export`.
4. If the user genuinely hasn't set it anywhere, the skill gives the copy-pasteable
   set command (per Step 4b) — never just a "show the token" command.

**Must not:** tell a user who already stored a credential in `~/.scoutflo/env` to
set it again; recommend only a bare per-shell `export` as the persistence path;
claim "set once, global" while `doctor` fails to source `~/.scoutflo/env`; or read
the secret value to decide any of this (presence-only).
