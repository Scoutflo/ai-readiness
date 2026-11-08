#!/bin/sh
# Execute the published config reader, target enumerator and LGTM selector.
# Table/guard checks cover their linkage; they do not simulate a model audit.
# An optional root supports replay against a frozen source tree. No provider calls.
set -eu
ROOT="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
python3 - "$ROOT" <<'PY'
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

root = pathlib.Path(sys.argv.pop()).resolve()
all_skill = (root / 'skills/audit-all/SKILL.md').read_text()
lgtm_skill = (root / 'skills/audit-lgtm/SKILL.md').read_text()
reader = next(block for block in re.findall(r'```bash\n(.*?)\n```', all_skill, re.S)
              if "awk -F: '/^[a-z_]+:/{print $1}'" in block)
selector = lgtm_skill.split('LG_KIND="$(sh "$TT" "$CFG" lgtm kind', 1)[1]
selector = 'LG_KIND="$(sh "$TT" "$CFG" lgtm kind' + selector.split('# For every configured *_env key:', 1)[0]
single = 'lgtm:\n  runtime_mode: external\n'
stacks = '''lgtm:
  - label: west
    runtime_mode: external
    loki_url: https://west.example.test
  - label: east
    runtime_mode: external
    loki_url: https://east.example.test
'''

def mappings(text, key):
    phase = text.split('Map keys to audits:', 1)[1].split('## Phase 2', 1)[0]
    result = []
    for line in phase.splitlines():
        cells = line.split('|')
        if line.startswith('|') and len(cells) >= 4 and '`' + key + '`' in cells[1]:
            result.extend(re.findall(r'`(audit-[a-z-]+)`', cells[2]))
    return result

class PlanLinkage(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = pathlib.Path(self.temp.name)
        bindir = self.work / 'bin'
        bindir.mkdir()
        for name in ('sh', 'awk', 'sed', 'tr', 'cat', 'grep', 'head', 'tail', 'basename', 'ls'):
            path = shutil.which(name)
            self.assertIsNotNone(path, name)
            (bindir / name).symlink_to(path)
        # A closed PATH prevents access to inherited CLIs or credentials. The yq
        # refusal selects the supported awk path without any ambient parser.
        for name in ('yq', 'curl', 'wget', 'gcloud', 'aws', 'kubectl', 'az', 'doctl', 'gh', 'claude'):
            path = bindir / name
            path.write_text('#!/bin/sh\nexit 99\n')
            path.chmod(0o700)
        self.env = {'PATH': str(bindir), 'HOME': str(self.work), 'LC_ALL': 'C',
                    'CLAUDE_PLUGIN_ROOT': str(root)}
        self.config = self.work / 'toolkit.yaml'

    def command(self, args, extra=None):
        return subprocess.run(args, cwd=self.work, env={**self.env, **(extra or {})},
                              capture_output=True, text=True, timeout=15)

    def keys(self, config):
        self.config.write_text(config)
        result = self.command(['/bin/sh', '-c', reader], {'SCOUTFLO_CONFIG': str(self.config)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.splitlines()

    def select(self, target):
        return self.command(['/bin/sh', '-c', 'set -eu\n' + selector +
                             '\nprintf "SELECTED=%s|%s|%s\\n" "$LG_LABEL" "$LG_SEG" "${LOKI_URL:-}"\n'],
                            {'TT': str(root / 'report-standard/toolkit-targets.sh'),
                             'CFG': str(self.config), 'SCOUTFLO_TARGET': target})

    def test_own_block_list_reaches_each_selected_stack(self):
        self.assertEqual(self.keys(stacks), ['lgtm'])
        self.assertEqual(mappings(all_skill, 'lgtm'), ['audit-lgtm'])
        labels = self.command(['/bin/sh', str(root / 'report-standard/toolkit-targets.sh'),
                               str(self.config), 'lgtm', 'labels'])
        self.assertEqual(labels.returncode, 0, labels.stderr)
        self.assertEqual(labels.stdout.splitlines(), ['west', 'east'])
        for target in labels.stdout.splitlines():
            with self.subTest(target=target):
                result = self.select(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('SELECTED=' + target + '|lgtm/' + target + '|https://' + target + '.example.test', result.stdout)

    def test_single_mapping_keeps_flat_target_and_ignores_unrelated_selector(self):
        self.assertEqual(self.keys(single), ['lgtm'])
        self.assertEqual(mappings(all_skill, 'lgtm'), ['audit-lgtm'])
        for target in ('', 'other-provider-label'):
            with self.subTest(target=target):
                result = self.select(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('SELECTED=lgtm|lgtm|', result.stdout)

    def test_unknown_list_label_cannot_fall_back(self):
        self.keys(stacks)
        result = self.select('est')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('matches no lgtm target', result.stdout)
        self.assertNotIn('SELECTED=', result.stdout)

    def test_legacy_backend_triggers_are_preserved(self):
        for backend in ('prometheus', 'loki', 'tempo', 'mimir', 'victoriametrics'):
            with self.subTest(backend=backend):
                self.assertEqual(self.keys(backend + ':\n  url: https://legacy.example.test\n'), [backend])
                self.assertIn('audit-lgtm', mappings(all_skill, backend))
        self.assertIn('audit-prometheus', mappings(all_skill, 'prometheus'))

    def test_own_stack_selection_does_not_use_legacy_backend_url(self):
        self.assertEqual(self.keys(stacks + 'loki:\n  url: https://legacy.example.test\n'), ['lgtm', 'loki'])
        for target in ('west', 'east'):
            result = self.select(target)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('|https://' + target + '.example.test', result.stdout)
            self.assertNotIn('legacy.example.test', result.stdout)

    def gate(self, text):
        fixture = self.work / 'gate-root'
        for skill in (root / 'skills').glob('audit-*'):
            (fixture / 'skills' / skill.name).mkdir(parents=True, exist_ok=True)
        (fixture / 'skills/audit-all/SKILL.md').write_text(text)
        return self.command(['/bin/sh', str(root / 'ci/audit-all-map-check.sh'), str(fixture)])

    def test_mapping_guard_rejects_missing_or_misdirected_own_block(self):
        result = self.gate(all_skill)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        own_rows = [line for line in all_skill.splitlines()
                    if line.startswith('|') and '`lgtm`' in line.split('|')[1]]
        self.assertEqual(len(own_rows), 1, 'lgtm needs one own-block mapping row')
        own = own_rows[0]
        mutations = {
            'removed-own-row': all_skill.replace(own, ''),
            'prose-only': all_skill.replace(own, 'The lgtm block uses audit-lgtm.'),
            'wrong-audit': all_skill.replace(own, '| `lgtm` | `audit-grafana` |'),
            'wrong-key': all_skill.replace(own, '| `lgtm_other` | `audit-lgtm` |'),
            'reversed-columns': all_skill.replace(own, '| `audit-lgtm` | `lgtm` |'),
        }
        for name, text in mutations.items():
            with self.subTest(mutation=name):
                # The legacy row still mentions audit-lgtm in every mutation.
                self.assertIn('audit-lgtm', mappings(text, 'loki'))
                result = self.gate(text)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('lgtm -> audit-lgtm', result.stdout)

    def test_mapping_guard_still_covers_other_own_block_audits(self):
        text = all_skill.replace('| `gcp` | `audit-gcp` |', '| `gcp` | `audit-aws` |')
        self.assertNotEqual(text, all_skill)
        result = self.gate(text)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('audit-gcp', result.stdout)

unittest.main()
PY
