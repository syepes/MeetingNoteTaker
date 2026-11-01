import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[2]

class BuildWorkflowTests(unittest.TestCase):
    def test_directory_replacement_rolls_back(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            old, new = folder/'output', folder/'incoming'
            old.mkdir(); new.mkdir()
            (old/'value').write_text('previous'); (new/'value').write_text('next')
            script = '''source "$1"
            mv() { if [ "$1" = "$INCOMING" ]; then return 1; else command mv "$@"; fi; }
            replace_directory "$INCOMING" "$OUTPUT"
            '''
            result = subprocess.run(['bash','-c',script,'check',str(ROOT/'scripts/replace-directory.sh')], env=dict(os.environ,INCOMING=str(new),OUTPUT=str(old)), capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((old/'value').read_text(),'previous')
            self.assertEqual((new/'value').read_text(),'next')

    def test_failed_restore_keeps_backup(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder); old=folder/'output'; new=folder/'incoming'
            old.mkdir(); new.mkdir(); (old/'value').write_text('previous')
            script = '''source "$1"
            mv() { if [ "$1" = "$OUTPUT" ]; then command mv "$@"; else return 1; fi; }
            replace_directory "$INCOMING" "$OUTPUT"
            '''
            result = subprocess.run(['bash','-c',script,'check',str(ROOT/'scripts/replace-directory.sh')],env=dict(os.environ,INCOMING=str(new),OUTPUT=str(old)),capture_output=True)
            self.assertNotEqual(result.returncode,0)
            backups=list(folder.glob('.previous.*/original/value'))
            self.assertEqual(len(backups),1)
            self.assertEqual(backups[0].read_text(),'previous')

    def test_invalid_configuration_or_signing_mode_rejected(self):
        for args, additions, message in [(['invalid'],{},'Configuration must be'), ([],{'RELEASE_SIGNING':'invalid'},'RELEASE_SIGNING must be'), ([],{'RELEASE_SIGNING':'notarized','SIGNING_IDENTITY':'-'},'Developer ID')]:
            with self.subTest(args=args, additions=additions):
                result=subprocess.run(['bash',str(ROOT/'scripts/build-app.sh'),*args], env=dict(os.environ,**additions),capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
                self.assertIn(message,result.stderr)

    def test_invalid_toolchain_rejected_without_global_change(self):
        before=subprocess.check_output(['xcode-select','-p'])
        result=subprocess.run(['bash','-c','source "$1"','check',str(ROOT/'scripts/build-env.sh')],env=dict(os.environ,DEVELOPER_DIR='/nonexistent/Xcode.app/Contents/Developer'),capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(before,subprocess.check_output(['xcode-select','-p']))

    def test_packaging_failures_preserve_previous_assets(self):
        import shutil
        import plistlib
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); (root/'scripts').mkdir(); (root/'bin').mkdir()
            for name in ('package-release.sh','release-version.py','replace-directory.sh'):
                shutil.copy2(ROOT/'scripts'/name,root/'scripts'/name)
            (root/'scripts/build-env.sh').write_text('true\n')
            (root/'scripts/validate-platform.py').write_text('pass\n')
            app_name=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())['CFBundleExecutable']
            app=root/'dist'/f'{app_name}.app'/'Contents'; app.mkdir(parents=True)
            (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'0.1.0'}))
            assets=root/'dist/release';assets.mkdir();(assets/'previous.zip').write_bytes(b'previous release')
            for name,body in [('codesign','echo Signature=adhoc >&2; exit 0'),('ditto','exit 71'),('xcrun','exit 99')]:
                tool=root/'bin'/name;tool.write_text('#!/bin/sh\n'+body+'\n');tool.chmod(0o755)
            for tag,mode,message in [('v0.2.0','adhoc','does not match'),('v0.1.0','invalid','RELEASE_SIGNING must be'),('v0.1.0','adhoc','')]:
                with self.subTest(tag=tag,mode=mode):
                    result=subprocess.run(['bash',str(root/'scripts/package-release.sh'),tag],env=dict(os.environ,PATH=str(root/'bin')+':'+os.environ['PATH'],RELEASE_SIGNING=mode),capture_output=True,text=True)
                    self.assertNotEqual(result.returncode,0)
                    if message:self.assertIn(message,result.stderr)
                    self.assertEqual(list(assets.iterdir()),[assets/'previous.zip'])
                    self.assertEqual((assets/'previous.zip').read_bytes(),b'previous release')
                    self.assertEqual(list(root.glob('.build/release-package.*')),[])

    def test_toolchain_setup_does_not_leak_compiler_environment_into_tests(self):
        env=dict(os.environ)
        for key in ('SDKROOT','CC','CXX','MACOSX_DEPLOYMENT_TARGET'):
            env.pop(key,None)
        script='''original_path="$PATH"
        source "$1" || exit 1
        [ "$PATH" = "$original_path" ] &&
        [ -z "${SDKROOT+x}${CC+x}${CXX+x}${MACOSX_DEPLOYMENT_TARGET+x}" ]
        '''
        result=subprocess.run(['bash','-c',script,'check',str(ROOT/'scripts/build-env.sh')],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
