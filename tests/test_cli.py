import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CLI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.binary = str(Path(cls.build.name) / 'simutex-fixture')
        subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-Wno-deprecated-declarations', '-I', str(ROOT/'src'), str(ROOT/'src/cli_bridge.m'), str(ROOT/'tests/cli_fixture.m'), '-framework', 'Foundation', '-o', cls.binary], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith('SIMUTEX_')}
        self.env.update(SIMUTEX_STATE_DIR=str(self.path/'locks'), SIMUTEX_METADATA_PATH=str(self.path/'metadata.json'))

    def tearDown(self): self.temp.cleanup()

    def run_cli(self, *args, ok=True):
        p = subprocess.run([self.binary, *args], env=self.env, text=True, capture_output=True, timeout=10)
        if ok: self.assertEqual(p.returncode, 0, p.stderr)
        else: self.assertNotEqual(p.returncode, 0, p.stdout)
        return p

    def config(self, name, value):
        path = self.path/name
        path.write_text(json.dumps(value))
        return str(path)

    def hook(self, text, timeout=60):
        return {'argv':['/bin/sh','-c',text], 'timeout_seconds':timeout}

    def test_metadata_and_legacy(self):
        self.run_cli('describe','SIM-1','Checkout only\nStaging "account"')
        rows=json.loads(self.run_cli('list','--json').stdout)['devices']
        self.assertEqual(rows[0]['description'], 'Checkout only\nStaging "account"')
        self.assertIsNone(rows[0]['owner'])
        self.run_cli('claim','SIM-1','--owner','legacy',ok=False)
        os.symlink('legacy', self.path/'locks/SIM-1.lock')
        self.run_cli('claim','SIM-1','--owner','legacy')
        self.run_cli('release','SIM-1','--owner','legacy')
        self.run_cli('describe','SIM-1','')
        self.assertEqual(json.loads(self.run_cli('status','SIM-1','--json').stdout)['description'],'')

    def test_contention_and_takeover(self):
        def claim(i):
            return subprocess.run([self.binary,'claim','SIM-1','--owner',f'agent:job-{i}'],env=self.env,capture_output=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex: results=list(ex.map(claim,range(8)))
        self.assertEqual(sum(p.returncode==0 for p in results),1)
        owner=json.loads(self.run_cli('status','SIM-1','--json').stdout)['owner']
        self.run_cli('takeover','SIM-1','--owner','manual:test','--expected-owner','stale',ok=False)
        self.run_cli('takeover','SIM-1','--owner','manual:test','--expected-owner',owner)
        self.run_cli('release','SIM-1','--owner',owner,ok=False)
        self.run_cli('release','SIM-1','--owner','manual:test')

    def test_hook_order_and_output(self):
        log=self.path/'log'
        file=self.config('hooks.json', {'pre_claim':self.hook(f'test ! -L "$SIMUTEX_STATE_DIR/$SIMUTEX_UDID.lock"; echo pre >> "{log}"'), 'post_claim':self.hook(f'test -L "$SIMUTEX_STATE_DIR/$SIMUTEX_UDID.lock"; echo post >> "{log}"; echo noise')})
        p=self.run_cli('claim','SIM-1','--owner','agent:test','--hooks',file)
        self.assertEqual(p.stdout,'SIM-1\n'); self.assertIn('noise',p.stderr)
        self.run_cli('claim','SIM-1','--owner','agent:test','--hooks',file)
        self.assertEqual(log.read_text(),'pre\npost\n')

    def test_failures_preserve_correct_state(self):
        pre=self.config('pre.json',{'pre_claim':self.hook('exit 7')})
        self.run_cli('claim','SIM-1','--owner','agent:test','--hooks',pre,ok=False)
        self.assertFalse((self.path/'locks/SIM-1.lock').is_symlink())
        post=self.config('post.json',{'post_claim':self.hook('sleep 5',0.05)})
        p=self.run_cli('claim','SIM-1','--owner','agent:test','--hooks',post,ok=False)
        self.assertEqual(p.stdout,''); self.assertIn('SIM-1',p.stderr)
        self.assertEqual(os.readlink(self.path/'locks/SIM-1.lock'),'agent:test')

    def test_device_precedence_and_inherit(self):
        defaults=self.config('defaults.json',{'pre_claim':self.hook('exit 9')})
        custom=self.config('custom.json',self.hook('echo device'))
        self.run_cli('hooks','set','SIM-1','--event','pre-claim','--config',custom)
        p=self.run_cli('claim','SIM-1','--owner','agent:test','--hooks',defaults)
        self.assertIn('device',p.stderr)
        self.run_cli('release','SIM-1','--owner','agent:test')
        self.run_cli('claim','SIM-2','--owner','agent:test','--hooks',defaults,ok=False)
        self.run_cli('hooks','disable','SIM-2','--event','pre-claim')
        self.run_cli('claim','SIM-2','--owner','agent:test','--hooks',defaults)
        self.run_cli('release','SIM-2','--owner','agent:test')
        self.run_cli('hooks','inherit','SIM-2','--event','pre-claim')
        self.run_cli('claim','SIM-2','--owner','agent:test','--hooks',defaults,ok=False)
        self.run_cli('claim','SIM-2','--owner','agent:test','--hooks',defaults,'--no-pre-claim')

    def test_concurrent_metadata(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
            list(ex.map(lambda i:self.run_cli('describe',f'SIM-{i}',f'Description {i}'),range(16)))
        self.assertEqual(len(json.loads((self.path/'metadata.json').read_text())['devices']),16)

    def test_hook_context_and_unlocked_guard(self):
        hook=self.config('other.json', {'pre_claim': {'argv':[self.binary,'claim','SIM-2','--owner','agent:other']}, 'post_claim': self.hook('test "$SIMUTEX_OWNER" = agent:test && test "$SIMUTEX_UDID" = SIM-1 && test "$SIMUTEX_HOOK_EVENT" = post-claim && test "$SIMUTEX_OPERATION" = claim')})
        self.run_cli('claim','SIM-1','--owner','agent:test','--hooks',hook)
        self.assertEqual(os.readlink(self.path/'locks/SIM-2.lock'),'agent:other')

    def test_takeover_rechecks_after_pre_hook(self):
        self.run_cli('claim','SIM-1','--owner','agent:old')
        hook=self.config('race.json', {'pre_claim':self.hook(f'"{self.binary}" release SIM-1 --owner agent:old && "{self.binary}" claim SIM-1 --owner agent:new')})
        self.run_cli('takeover','SIM-1','--owner','manual:test','--expected-owner','agent:old','--hooks',hook,ok=False)
        self.assertEqual(os.readlink(self.path/'locks/SIM-1.lock'),'agent:new')

    def test_relative_hook_and_override(self):
        script=self.path/'hook.sh'; script.write_text('#!/bin/sh\necho relative\n'); script.chmod(0o700)
        config=self.config('relative.json',{'pre_claim':{'argv':['./hook.sh']}})
        p=self.run_cli('claim','SIM-1','--owner','agent:test','--hooks',config)
        self.assertIn('relative',p.stderr)
        self.run_cli('claim','SIM-2','--owner','agent:test','--hooks',config,'--pre-claim','/usr/bin/false',ok=False)
        self.run_cli('claim','SIM-2','--owner','agent:test','--hooks',config,'--pre-claim','/usr/bin/true')

    def test_validation_and_description_option_terminator(self):
        self.run_cli('claim','SIM-1','--owner','agent:bad\nname',ok=False)
        self.run_cli('release','SIM-1','--owner','agent:test','--no-pre-claim',ok=False)
        self.run_cli('claim','SIM-1','--owner','agent:test','--pre-claim','/usr/bin/true','--no-pre-claim',ok=False)
        self.run_cli('describe','--','SIM-1','--only checkout')
        self.assertEqual(json.loads(self.run_cli('status','SIM-1','--json').stdout)['description'],'--only checkout')

    def test_watch_updates(self):
        p=subprocess.Popen([self.binary,'watch','--json'],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertEqual(len(json.loads(p.stdout.readline())['devices']),2)
            self.run_cli('describe','SIM-1','Watch changed')
            self.assertEqual(json.loads(p.stdout.readline())['devices'][0]['description'],'Watch changed')
        finally:
            p.terminate(); p.communicate(timeout=5)

if __name__=='__main__': unittest.main()
