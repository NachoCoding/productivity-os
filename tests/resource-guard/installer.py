"""Exercise the installer's actual instruction updater in a disposable home."""
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parents[2]
script = (project / 'assets/setup-resource-guard.sh').read_text()
function = script.split('update_instructions() {', 1)[1].split('\nPERL\n}', 1)[0] + '\nPERL'
shell = 'set -euo pipefail\nassets_dir="$1"\nupdate_instructions() {' + function + '\n}\nupdate_instructions "$2" "$3"'

with tempfile.TemporaryDirectory(prefix='rg-instructions-') as temporary:
    root = Path(temporary)
    target = root / 'AGENTS.md'
    original = '# Existing user rules\n\nKeep my projects safe.\n'
    target.write_text(original)

    def update(action, file=target, check=True):
        return subprocess.run(['/bin/bash', '-c', shell, 'test', str(project / 'assets'), str(file), action],
                              capture_output=True, text=True, check=check)

    update('install')
    once = target.read_text()
    assert once.startswith(original) and '## Resource Guard' in once
    update('install')
    assert target.read_text() == once
    backups = list(root.glob('AGENTS.md.resource-guard-backup-*'))
    assert len(backups) == 2 and any(file.read_text() == original for file in backups)
    update('uninstall')
    assert target.read_text().startswith(original) and '## Resource Guard' not in target.read_text()
    target.write_text(original + '<!-- productivity-os-resource-guard:start -->\nmalformed')
    before = target.read_text()
    assert update('install', check=False).returncode != 0 and target.read_text() == before
    link = root / 'symlink.md'
    link.symlink_to(target)
    assert update('install', file=link, check=False).returncode != 0 and target.read_text() == before
print('Resource Guard instruction installation tests passed')
