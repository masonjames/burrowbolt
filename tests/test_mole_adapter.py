#!/usr/bin/env python3
"""Exercise the real patched Mole boundary under an isolated test HOME. Never removes user data."""
import os, pathlib, selectors, signal, subprocess, tempfile, time, unittest, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
ADAPTER=ROOT/'build/BurrowBolt.app/Contents/Resources/adapter.sh'
class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='burrowbolt-adapter-')
        self.home=pathlib.Path(self.temp.name)
        self.first=self.home/'Library/Logs/FixtureOne'
        self.second=self.home/'Library/Logs/FixtureTwo'
        for path in (self.first,self.second):
            path.mkdir(parents=True); (path/'log.txt').write_bytes(b'fixture\n'*1024)
        self.env={**os.environ,'HOME':str(self.home),'TMPDIR':str(self.home), 'MOLE_TEST_NO_AUTH':'1'}
    def tearDown(self): self.temp.cleanup()
    def run_adapter(self,path,mode,expect_grant=False):
        process=subprocess.Popen(['/bin/bash',str(ADAPTER),str(path),mode,str(self.home)],
            stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=self.env,start_new_session=True)
        poll=selectors.DefaultSelector(); poll.register(process.stdout,selectors.EVENT_READ)
        output=b''; deadline=time.monotonic()+30
        try:
            while time.monotonic()<deadline:
                if poll.select(.1):
                    data=os.read(process.stdout.fileno(),65536)
                    if not data: break
                    output+=data
                    if expect_grant and b'allowed\n' in output: break
            else: self.fail('Adapter exceeded test deadline')
        finally:
            try: os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            except PermissionError:
                if process.poll() is None: process.kill()
            self.last_returncode=process.wait(); poll.close(); process.stdout.close()
        return output
    def test_family_discovery_and_exact_selected_boundary(self):
        records=self.run_adapter('/', 'discover:clean_user_essentials')
        self.assertIn(str(self.first).encode()+b'\0review\0',records)
        self.assertIn(str(self.second).encode()+b'\0review\0',records)
        # Regression for Bash dynamic scope: a local `path` in _safe_clean_impl
        # must never replace the adapter's selected path.
        output=self.run_adapter(self.home/'not-selected','family:clean_user_essentials')
        self.assertNotIn(b'allowed',output)
        output=self.run_adapter(self.second,'family:clean_user_essentials',True)
        self.assertEqual(output,b'allowed\n')
        self.assertTrue(self.first.exists()); self.assertTrue(self.second.exists())
    def test_symlink_and_unknown_rule_are_refused(self):
        path=self.home/'Installer.dmg'; path.symlink_to(self.first/'log.txt')
        for kind in ('installer','unknown'):
            self.assertNotIn(b'allowed',self.run_adapter(path,kind))
    def test_zip_classification_uses_complete_mole_listing(self):
        installer=self.home/'Installer with spaces.zip'
        ordinary=self.home/'Archive.zip'
        for path,name in ((installer,'Example.app/Contents/Info.plist'),(ordinary,'family-photo.txt')):
            with zipfile.ZipFile(path,'w') as archive: archive.writestr(name,'fixture')
        self.assertEqual(self.run_adapter(installer,'inspect-zip'),b'allowed\n')
        self.assertNotIn(b'allowed',self.run_adapter(ordinary,'inspect-zip'))
        self.assertEqual(self.run_adapter(installer,'installer-zip'),b'allowed\n')
        self.assertNotIn(b'allowed',self.run_adapter(ordinary,'installer-zip'))
        self.assertTrue(installer.exists());self.assertTrue(ordinary.exists())
    def test_open_installer_is_not_granted(self):
        path=self.home/'Open.dmg';path.write_bytes(b'fixture')
        with path.open('rb') as active:
            self.assertNotIn(b'allowed',self.run_adapter(path,'installer'))
            self.assertEqual(active.read(),b'fixture')
    def test_nonrequired_family_status_and_reset_deadline_match_mole_caller(self):
        for family in ('clean_app_caches','run_cloud_and_office_cleanup','clean_user_gui_applications'):
            self.run_adapter('/', 'discover:'+family)
            self.assertEqual(self.last_returncode,0,family)
    def test_namespace_does_not_write_mole_preferences(self):
        self.run_adapter('/', 'discover:clean_user_essentials')
        self.assertFalse((self.home/'.config/mole').exists())
        self.assertFalse((self.home/'Library/Logs/mole').exists())
        self.assertTrue((self.home/'Library/Logs/BurrowBolt').exists())
if __name__=='__main__': unittest.main()
