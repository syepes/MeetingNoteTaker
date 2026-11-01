import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[2]


class SigningTests(unittest.TestCase):
    def test_import_refuses_local_pr_and_self_hosted_contexts(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            # Never invoke the real credential tools, even if the guard regresses.
            marker = directory / 'credential-tool-called'
            for name in ('security', 'xcrun', 'openssl'):
                tool = directory / name
                tool.write_text(f'#!/bin/sh\ntouch "{marker}"\nexit 99\n')
                tool.chmod(0o755)
            env = dict(os.environ, PATH=f'{folder}:' + os.environ['PATH'],
                       RUNNER_TEMP=folder, GITHUB_ENV=str(directory / 'env'),
                       MACOS_CERTIFICATE_BASE64='dummy', MACOS_CERTIFICATE_PASSWORD='dummy',
                       MACOS_SIGNING_IDENTITY='Developer ID Application: Test',
                       NOTARY_KEY_BASE64='dummy', NOTARY_KEY_ID='dummy', NOTARY_ISSUER_ID='dummy')
            for actions, runner, event, ref in [('false', 'github-hosted', 'push', 'tag'),
                                               ('true', 'github-hosted', 'pull_request', 'branch'),
                                               ('true', 'self-hosted', 'push', 'tag')]:
                with self.subTest(actions=actions, runner=runner, event=event):
                    result = subprocess.run(['bash', str(ROOT / 'scripts/ci-signing.sh')],
                                            env=dict(env, GITHUB_ACTIONS=actions, RUNNER_ENVIRONMENT=runner,
                                                     GITHUB_EVENT_NAME=event, GITHUB_REF_TYPE=ref),
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('restricted to tag pushes', result.stderr)
                    self.assertFalse(marker.exists())
                    self.assertFalse((directory / 'env').exists())
