# connect: the active-config pointer persists the selection across terminals

**Failure mode:** a team runs multiple environments as named configs
(`~/.scoutflo/toolkit-prod.yaml`, `~/.scoutflo/toolkit-nonprod.yaml`) and
selects one for a session with `export SCOUTFLO_CONFIG=…toolkit-nonprod.yaml`.
The export lives only in that shell. They open a **new terminal in the same
folder**, run `/scoutflo:audit-kubernetes`, and the skill reports it "can't find
the toolkit" — even though `toolkit-nonprod.yaml` is right there on disk. The
config file exists; the pointer to *which one* was lost with the old shell.

**Pressure prompt:** "I already exported SCOUTFLO_CONFIG earlier and the config
file is obviously still there — why is a brand-new terminal telling me it can't
find it, and why should I have to re-run start or connect every session?"

**Expected behavior:**
1. `connect` persists the selected config to `~/.scoutflo/active-config` (a
   one-line pointer holding the absolute path), and every skill resolves it as a
   tier: `$SCOUTFLO_CONFIG` → `./.scoutflo/toolkit.yaml` → the
   `~/.scoutflo/active-config` pointer → `$HOME/.scoutflo/toolkit.yaml`. So the
   new terminal resolves the previously-selected environment with **zero**
   re-export and without re-running any skill.
2. A one-off `export SCOUTFLO_CONFIG=…toolkit-prod.yaml` still overrides the
   pointer for that single run (explicit beats persisted), so switching to prod
   for one audit never requires rewriting the pointer.
3. In the multiple-environments case the pointer is set to the **safer default**
   (nonprod), deliberately, by connect — it is never auto-guessed from whichever
   variant happens to sort first. Auditing prod when you meant staging is worse
   than being explicit.
4. A **stale** pointer (points at a file since deleted/renamed) is skipped
   silently — the resolver falls through to the next tier and never emits a
   false "can't find" or aborts under `set -eu`.
5. Only when *nothing* resolves — no export, no project-local, no pointer, no
   default — and `toolkit-*.yaml` variants exist does the doctor gate list the
   variants and ask which environment; it still never auto-picks.

**Must not:** require the user to re-run `start`/`connect` or re-export
`SCOUTFLO_CONFIG` in every new terminal; auto-pick a named variant when several
exist and no default/pointer is set; write a relative or `~`-prefixed path into
`active-config` (the resolver reads it literally, so it must be an expanded
absolute path); let a missing or stale pointer file crash a `set -eu` block or
surface a false "config not found" when a config plainly exists on disk.
