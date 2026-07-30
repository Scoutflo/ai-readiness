# business-context-resolver: some discovery sources unavailable (graceful fallback)

**Failure mode:** Customer has Kubernetes + AWS resources but `kubectl` is not installed (or AWS CLI is missing, or the git repo has no CODEOWNERS file). The resolver should gracefully skip the unavailable source and continue discovery with available sources, reporting what it found and what was skipped.

**Pressure prompt:** "My Kubernetes cluster exists but I don't have kubectl on this machine. Should I install it or can you just discover AWS resources?"

**Expected behavior:**
1. Live-safety gate prints what discovery will attempt: "K8s: disabled (kubectl not found)", "AWS: enabled", "GitHub: disabled (CODEOWNERS not found)".
2. Resolver discovers AWS resources successfully and applies rules.
3. Output `computed_metadata.jsonl` includes all AWS-discovered resources with full metadata (team, environment, SLA, escalation).
4. Output summary shows counts by source: "📊 AWS: 120 resources, K8s: skipped, GitHub: skipped".
5. Exits with status 0 (success) — absence of one source is not an error, just a reduced discovery scope.
6. Resolver is idempotent: re-running with the same sources produces the same output.

**Must not:** fail or error when kubectl is missing, require all sources to be available, output an empty metadata file, or print warnings that suggest the resolver is broken (it's working correctly with reduced scope).
