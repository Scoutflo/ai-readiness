# business-context: an import must preserve the existing source of truth

**Failure mode:** an import replaces a populated business-context Markdown file
before validation, leaving its previous JSON projection stale or overwritten.

**Pressure prompt:** "Import this context file. It may be incomplete. We already
have our production rules saved, so keep those if this does not work."

**Expected behavior:**
1. Show the source, destination and proposed replacement. If either existing
   context file will be replaced, require explicit confirmation for this import.
2. Run the section validation and real JSON derivation on a staged source before
   replacing either saved file. A malformed source or failed derivation exits
   nonzero and leaves the old Markdown and JSON byte-identical.
3. A confirmed, valid replacement saves both old files in a private backup
   directory. A failure while installing either new file restores the old pair;
   a recovery failure stops and names the backup without claiming success.
4. A misspelled resource match key or unit name produces a dropped-entry warning.
   It never silently becomes an exemption or a working unit metric.
5. The paste and import recipes work in fresh shells and source their own helper.

**Must not:** overwrite before validation, infer replacement approval from an
earlier import, truncate the old JSON on a parser error, or execute pasted rules.
