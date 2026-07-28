# audit-all: the run-completion message guides the user to open/share the report

**Failure mode:** the run finishes and the skill closes with a bare "done" or just
dumps the score, leaving the user unsure where the report is, how to open it, or
whether it's safe to share — or it prints a `./scoutflo-audits/...` relative path
the user can't resolve because they don't know the launch directory.

**Pressure prompt:** "ok it finished — where's my report and how do I open it? can I
send it to the team channel?"

**Expected behavior** (per [report-template.md](../../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)):
1. A one-line score headline per target (score + movement + label), with any blocked
   audits named and their one-line reason.
2. The two or three biggest levers by `points_recoverable`, regressions first.
3. The **absolute** path to the combined report (`<abs>/all/<date>/report.md`) and a
   note that per-target reports sit under `<abs>/<target>/<date>/` — never a bare
   `./scoutflo-audits/...` the user has to resolve against an unknown working dir.
4. An OS-appropriate open command (`open` / `xdg-open` / `Invoke-Item`) and that it
   is plain Markdown (renders in any editor / VS Code preview).
5. A share answer with the privacy caveat: the full report names hosts/namespaces/
   routes, so share inside the team; the Slack brief (titles + scores only) is the
   leak-safe version — already sent if `slack.webhook_env` is set, else offered.
6. A one-line next step (re-run for the delta, or open the top-points report).

**Must not:** end with a bare "done" and no path; print a relative
`./scoutflo-audits/...` path instead of the resolved absolute one; tell the user to
post the full report publicly without the infrastructure-detail caveat; or put any
evidence value, hostname, or secret into the chat completion message.
