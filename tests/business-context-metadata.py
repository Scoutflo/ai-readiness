"""Exercise published Metadata Load fences, never a replacement implementation."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(sys.argv[1]).resolve()
MARKDOWN = """# Business Context

## Environment
- **Stage:** staging

## Cost Sensitivity
- **Primary:** high

## Critical Services
- `checkout`

## Exclusions
- `archive-db`
"""
WORKSPACE = {
    "environment": "production",
    "cost_sensitivity": "low",
    "critical_dependencies": ["billing"],
    "exclusions": {"resources": ["standby-db"]},
}
RESOURCE = '{"resource_id":"checkout","escalation":"CRITICAL"}\n'
MD_VALUES = ("staging", "high", "checkout", "archive-db")
JSON_VALUES = ("production", "low", "billing", "standby-db")
EMPTY_VALUES = ("", "", "", "")
# Expected values distinguish the selected workspace source from the resource
# cache. A per-resource record must not replace either workspace source.
CASES = [
    ("markdown-only", MARKDOWN, None, None, "ssot-md", "business_context.md", 0, MD_VALUES),
    ("json-only", None, json.dumps(WORKSPACE), None, "workspace", "business_context.json", 0, JSON_VALUES),
    ("json-and-resource", MARKDOWN, json.dumps(WORKSPACE), RESOURCE, "per-resource+workspace", "business_context.json", 1, JSON_VALUES),
    ("markdown-and-resource", MARKDOWN, None, RESOURCE, "per-resource+ssot-md", "business_context.md", 1, MD_VALUES),
    ("invalid-json-fallback", MARKDOWN, "{invalid-json", RESOURCE, "per-resource+ssot-md", "business_context.md", 1, MD_VALUES),
    ("invalid-resource-cache", MARKDOWN, None, "{invalid-resource", "ssot-md", "business_context.md", 0, MD_VALUES),
    ("resource-only", None, None, RESOURCE, "per-resource", "", 1, EMPTY_VALUES),
    ("no-context", None, None, None, "none", "", 0, EMPTY_VALUES),
]
PROBE = r'''
printf 'METADATA_TEST:'
jq -nc --arg mode "$LOAD_METADATA_MODE" --arg source "${BC_SRC##*/}" \
  --arg environment "${ENVIRONMENT-}" --arg cost "${COST_SENSITIVITY-}" \
  --arg critical "${CRITICAL-}" --arg exclusions "${EXCLUSIONS-}" \
  --argjson per_resource "$HAVE_PER_RESOURCE" \
  '{mode:$mode,source:$source,per_resource:$per_resource,values:[$environment,$cost,$critical,$exclusions]}'
'''


def main():
    failures = []
    passed = 0
    audits = [p for p in sorted((ROOT / "skills").glob("audit-*/SKILL.md"))
              if p.parent.name not in {"audit-all", "audit-cost"}]
    if not audits:
        raise AssertionError("No scored-audit producers discovered")
    with tempfile.TemporaryDirectory(prefix="metadata-load-") as temp:
        work = Path(temp)
        bindir = work / "bin"
        bindir.mkdir()
        # Only the local text utilities used by these fences are available.
        for name in ("jq", "grep", "awk", "sed", "head", "tr"):
            executable = shutil.which(name)
            if executable is None:
                raise AssertionError("Missing local test dependency: " + name)
            (bindir / name).symlink_to(executable)
        calls = work / "unexpected-provider-calls"
        for name in ("aws", "gcloud", "kubectl", "curl", "wget", "doctl", "bq", "az", "gh", "claude", "terraform"):
            stub = bindir / name
            stub.write_text('#!/bin/sh\nprintf "%s\\n" blocked >> "$BC_TEST_CALLS"\nexit 97\n')
            stub.chmod(0o700)
        home = work / "home"
        store = home / ".scoutflo"
        store.mkdir(parents=True)
        env = {
            "PATH": str(bindir), "HOME": str(home), "LC_ALL": "C",
            "XDG_CONFIG_HOME": str(home / ".config"),
            "AWS_CONFIG_FILE": str(home / ".aws/config"),
            "AWS_SHARED_CREDENTIALS_FILE": str(home / ".aws/credentials"),
            "CLOUDSDK_CONFIG": str(home / ".config/gcloud"),
            "KUBECONFIG": str(home / ".kube/config"),
            "BC_TEST_CALLS": str(calls),
        }
        for audit in audits:
            blocks = [b for b in re.findall(r"```bash\n(.*?)\n```", audit.read_text(), re.S)
                      if 'echo "metadata mode: $LOAD_METADATA_MODE"' in b]
            if len(blocks) != 1:
                failures.append(audit.parent.name + ": expected one real Metadata Load fence")
                continue
            for shell in ("/bin/sh", "/bin/bash"):
                for case, md, workspace, resource, mode, source, per_resource, values in CASES:
                    inputs = {"business_context.md": md, "business_context.json": workspace,
                              "computed_metadata.jsonl": resource}
                    for name, content in inputs.items():
                        path = store / name
                        if path.exists():
                            path.unlink()
                        if content is not None:
                            path.write_text(content)
                    before = {p.name: p.read_bytes() for p in store.iterdir()}
                    result = subprocess.run([shell, "-c", blocks[0] + "\n" + PROBE],
                                            cwd=work, env=env, text=True,
                                            capture_output=True, timeout=15)
                    rows = [line.removeprefix("METADATA_TEST:") for line in result.stdout.splitlines()
                            if line.startswith("METADATA_TEST:")]
                    try:
                        observed = json.loads(rows[0]) if len(rows) == 1 else None
                    except ValueError:
                        observed = None
                    expected = {"mode": mode, "source": source, "per_resource": per_resource,
                                "values": list(values)}
                    unchanged = before == {p.name: p.read_bytes() for p in store.iterdir()}
                    if (result.returncode == 0 and observed == expected and unchanged
                            and not result.stderr and not calls.exists()):
                        passed += 1
                    else:
                        failures.append(f"{audit.parent.name} {Path(shell).name} {case}: "
                                        f"exit={result.returncode}, observed={observed}, "
                                        f"expected={expected}, inputs_unchanged={unchanged}, "
                                        f"stderr={result.stderr.strip()!r}")
    for failure in failures:
        print("FAIL " + failure, file=sys.stderr)
    print(f"Metadata Load: {passed} passed, {len(failures)} failed across {len(audits)} scored audits; no provider calls")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
