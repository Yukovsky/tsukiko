"""Candidate signing never enables ad-hoc signing for main or release tags."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    with tempfile.TemporaryDirectory(prefix='tsukiko-sign-check-') as directory:
        root = Path(directory)
        (root / 'tool').mkdir()
        shutil.copyfile(Path(__file__).with_name('sign.sh'), root / 'tool/sign.sh')
        mock_bin = root / 'bin'
        mock_bin.mkdir()
        security = mock_bin / 'security'
        security.write_text('#!/bin/sh\necho "0 valid identities found"\n')
        security.chmod(0o755)
        env = dict(os.environ, PATH=str(mock_bin) + os.pathsep + os.environ['PATH'],
                   CI='true', TSUKIKO_ADHOC_SIGN='1', TSUKIKO_CANDIDATE_BUILD='1',
                   GITHUB_EVENT_NAME='workflow_dispatch', TSUKIKO_SIGNING_KEYCHAIN='')
        for ref, candidate in [('refs/heads/main', False), ('refs/tags/v1.5.4', False),
                               ('refs/heads/codex/paste-target-validation', True)]:
            result = subprocess.run(['sh', str(root / 'tool/sign.sh')], env=dict(env, GITHUB_REF=ref),
                                    capture_output=True, text=True)
            assert result.returncode != 0  # No engine bundle exists in this isolated test.
            if candidate:
                assert 'Нет движка' in result.stdout + result.stderr, result.stdout + result.stderr
            else:
                assert 'Нет сертификата' in result.stderr, result.stdout + result.stderr
    print('Candidate signing boundaries: all checks passed')


if __name__ == '__main__':
    main()
