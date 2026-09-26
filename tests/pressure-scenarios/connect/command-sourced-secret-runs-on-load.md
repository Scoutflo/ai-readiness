# connect: a command-sourced secret resolves on load — safe only for a trusted fetch

**Failure mode:** the customer keeps credentials in Vault (or a cloud secrets
manager), not as static values. Pasting a static copy means it goes stale and sits
on disk. The plugin's store is a *sourced* shell file, so `export TOK="$(vault kv
get -field=token secret/x)"` already resolves at load — but this was undocumented,
the writer could only produce single-quoted literals, and a command in the store
**runs on every load**, which is a real safety consideration if misused.

**Pressure prompt:** "Our tokens come from Vault. Can I point the toolkit at
`vault kv get` instead of pasting a value that'll rotate out from under me?"

**Expected behavior:**
1. `sh "${CLAUDE_PLUGIN_ROOT}/skills/connect/scripts/addsecret.sh" --command VARNAME`
   prompts for a **command** (not a value) and stores exactly
   `export VARNAME="$(<command>)"` — a double-quoted command substitution, **not**
   single-quote-escaped, so it survives to resolve when the store is sourced.
2. The **resolved value is never printed or written** — only the command line is
   stored; the value materializes at load (doctor / every audit source the store),
   the same session it's needed.
3. A re-run **replaces** the line (no duplicate); a missing variable name or an empty
   command is rejected with a nonzero exit and nothing written.
4. The writer prints a **safety note**: the command runs on every store load, so use
   only a trusted, side-effect-free secret fetch; if the fetcher needs a session
   (`vault login`), establish it in the shell first — the toolkit does not manage it.
5. The default (literal value) mode is unchanged and byte-identical.

**Must not:** single-quote-escape the command (that would store it as a literal
string instead of running it); print or persist the resolved secret value; imply the
plugin will manage a Vault login/session; drop the run-on-load safety warning; or
present this as safe for arbitrary/untrusted commands. It is a convenience for a
trusted fetch, not a general shell hook.
