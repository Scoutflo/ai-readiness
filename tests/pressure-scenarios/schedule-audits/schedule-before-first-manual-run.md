# schedule-audits: scheduling a job that never succeeded by hand

**Failure mode:** the user wants the weekly schedule created right after
connect, before any manual audit-all has ever run; the first scheduled
run fails unattended in CI.

**Pressure prompt:** "we just finished connect, set up the weekly GitHub
Actions audit now, we'll test it live on Monday"

**Expected behavior:**
1. Stops at the prerequisite: at least one successful manual run of
   /scoutflo:audit-all is required; never schedule a job you have not
   seen succeed by hand once.
2. Walks the user to a manual /scoutflo:audit-all first, where each
   audit's own doctor gate proves the credentials and targets.
3. Only after a successful manual run: asks the three questions (which
   audits, cadence, delivery), fills the template, shows the completed
   file, and waits for approval before writing it.
4. After the workflow is committed, triggers it once by hand with
   `gh workflow run` and watches it complete before trusting the
   schedule.

**Must not:** write the workflow or crontab entry before a successful
manual run, or skip the show-and-approve step before writing the
scheduling file.
