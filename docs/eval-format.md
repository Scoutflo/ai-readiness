# Behavioral evals format (`evals/evals.json`)

Our CI gates and the local self-test are **structural**: they prove a section exists, a prefix is registered, a score reconciles, an anchor resolves. They cannot prove the thing that actually breaks in the field — **behavioral SKILL-vs-reality drift**: given the skill, does the agent make the right calls, reach the right verdict, and refuse the documented traps? That failure class is our most expensive one (many bugs fixed only when a skill first met a real estate). Our `tests/pressure-scenarios/<skill>/*.md` files describe those traps in prose, but they are not gradeable or runnable.

This format — adopted from SigNoz's official agent-skills `evals/evals.json` — turns a pressure scenario into a **gradeable behavioral spec** that can be replayed against a frozen fixture with no live credentials. Authoring the specs is valuable on its own (they document expected behavior precisely); an LLM-judge runner is future work (see below).

## Location and schema

One file per skill: `skills/<skill-name>/evals/evals.json`. Offline fixture responses (captured provider payloads, redacted) live under `skills/<skill-name>/evals/files/`.

```json
{
  "skill_name": "audit-kubernetes",
  "evals": [
    {
      "id": 1,
      "eval_name": "jit-tunnel-down-is-a-dead-session-not-a-private-cluster",
      "prompt": "A realistic user request that should invoke this skill's behavior.",
      "expected_output": "Prose describing the correct end-state / verdict the agent should reach.",
      "expectations": [
        "Each line is one discrete, individually-checkable behavioral assertion.",
        "e.g. 'classifies a localhost connection-refused as a dead JIT session, not a private-cluster/RBAC failure'",
        "e.g. 'does NOT recommend widening authorized IP ranges for a localhost server'",
        "e.g. 'never fabricates a posture score when the cluster was not reached'"
      ],
      "files": ["kubeconfig-localhost-refused.json"]
    }
  ]
}
```

- **`prompt`** — a realistic request that should trigger the behavior (often a pressure prompt).
- **`expected_output`** — prose describing the correct behavior/verdict/tool sequence.
- **`expectations[]`** — the rubric: discrete lines a judge (human or LLM) checks independently. Each is a single claim, phrased so it is unambiguously pass/fail.
- **`files[]`** (optional) — names of offline fixtures under `evals/files/` the eval replays, so the behavior can be checked **without a live tenant** ("using the attached offline responses, do not query a live estate"). This maps onto our existing frozen "saved runs" / benchmark cold-storage idea.

## Relationship to pressure scenarios

`tests/pressure-scenarios/<skill>/*.md` stays the human-readable narrative (failure mode → pressure prompt → expected behavior → must-not). An `evals.json` entry is the **machine-gradeable projection** of that same scenario: its `expectations[]` are the scenario's "Expected behavior" and "Must not" lines, made discrete. When both exist, keep them consistent — the scenario is the prose, the eval is the checklist.

## Governance

Fixtures under `evals/files/` are **redacted** — no real credential, hostname, org slug, or customer identifier (the same forbidden-content rule as every tracked file; `ci/leak-scan.sh` still applies). Capture shapes/counts/field-names, not real values.

## Runner (future work — not yet built)

There is no LLM-judge runner wired into CI yet. `evals.json` files are authored as self-documenting specs now; a later change can add a judge (e.g. `claude plugin eval` or an equivalent harness) that replays each `prompt` (with `files[]` mounted) and scores against `expectations[]`. Until then: `run-tests.sh` does **not** execute `evals/` (it runs only `test-*.sh`/`measure-*.sh`), and `evals/` is a dev-only directory excluded from the shipped package (see [ship-manifest.md](ship-manifest.md)).
