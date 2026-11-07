#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json,os,pathlib,re,subprocess,sys,tempfile,unittest
root=pathlib.Path(sys.argv.pop())
block=next(b for b in re.findall(r'```bash\n(.*?)\n```',(root/'skills/setup-clickstack/SKILL.md').read_text(),re.S) if 'LATEST=' in b)
class Checks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.tmp.name);self.a=self.p/'audit space';(self.p/'home').mkdir();(self.p/'bin').mkdir()
  for name in ('curl','wget','aws','gcloud','kubectl'):
   f=self.p/'bin'/name;f.write_text('#!/bin/sh\necho forbidden >&2\nexit 99\n');f.chmod(0o755)
  self.cfg=self.p/'config.yaml';self.cfg.write_text('clickstack:\n  - label: east\n    hyperdx_url: https://east.example.test\n  - label: west\n    hyperdx_url: https://west.example.test\n')
  self.env={'PATH':str(self.p/'bin')+':'+os.environ['PATH'],'HOME':str(self.p/'home'),'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(self.cfg),'SCOUTFLO_AUDIT_DIR':str(self.a),'SCOUTFLO_TARGET':'east'}
 def tearDown(self):self.tmp.cleanup()
 def put(self,folder,title,report=True,target='clickstack/east',date=None):
  p=self.a/target/folder;p.mkdir(parents=True,exist_ok=True);(p/'findings.json').write_text(json.dumps({'target':target,'run_date':date or folder,'findings':[{'id':'CS-020','severity':'high','title':title,'remediation':'setup-clickstack#set-retention-ttl'}]}))
  if report:(p/'report.md').write_text('# Synthetic completed report\n')
 def runblock(self):return subprocess.run(['sh','-c',block],cwd=self.p,env=self.env,text=True,capture_output=True,timeout=20)
 def test_decoy_setup_run_and_incomplete_date_cannot_win(self):
  self.put('2000-01-01','older');self.put('2000-01-02','selected-completed')
  self.put('setup-z','setup-decoy',date='2000-01-03');self.put('runs/z','run-decoy',date='2000-01-03');self.put('2000-01-03','incomplete-decoy',report=False);self.put('2000-99-99','invalid-date-decoy');self.put('2000-01-04','other-target',target='clickstack/west')
  r=self.runblock();self.assertEqual(r.returncode,0,r.stderr);self.assertIn('selected-completed',r.stdout);self.assertNotIn('decoy',r.stdout);self.assertNotIn('other-target',r.stdout)
 def test_no_complete_audit_does_not_select_setup(self):
  self.put('setup-z','setup-decoy',date='2000-01-01');r=self.runblock();self.assertNotEqual(r.returncode,0);self.assertNotIn('setup-decoy',r.stdout)
 def test_envelope_date_mismatch_not_used_and_single_block_works(self):
  self.cfg.write_text('clickstack:\n  hyperdx_url: https://single.example.test\n');self.env.pop('SCOUTFLO_TARGET')
  self.put('2000-01-01','correct',target='clickstack');self.put('2000-01-02','wrong-date',target='clickstack',date='2000-01-03')
  r=self.runblock();self.assertEqual(r.returncode,0,r.stderr);self.assertIn('correct',r.stdout);self.assertNotIn('wrong-date',r.stdout)
unittest.main()
PY
