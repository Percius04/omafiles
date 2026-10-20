#!/usr/bin/env python3
"""Run native QML search tests or destructive selfcheck ONLY in a private bwrap home."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument('--build', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
modes = parser.add_mutually_exclusive_group()
modes.add_argument('--selfcheck', action='store_true')
modes.add_argument('--native', action='store_true')
parser.add_argument('cases', nargs='*')
a = parser.parse_args()
source, build, evidence = (p.resolve() for p in (a.source, a.build, a.evidence))
scratch = Path(tempfile.gettempdir()).resolve()
if not evidence.is_relative_to(scratch):
    parser.error('--evidence must be below the temporary directory (set TMPDIR to override)')
evidence.mkdir(parents=True, exist_ok=False, mode=0o700)
home, tmp = evidence / 'home', evidence / 'tmp'
for p in (home / '.cache', home / '.config', home / '.local/share/Trash/files',
          home / '.local/share/Trash/info', home / '.local/state', tmp):
    p.mkdir(parents=True, exist_ok=True)
f = home / 'hybrid-fixture'
for d in ('local/sub', 'outside', 'local/.hidden', 'local/node_modules/deep',
          'local/.cache/deep', 'local/.git/deep', 'local/.pnpm/deep',
          'local/.cargo/deep', 'local/.rustup/deep', 'many', 'exactly', 'ranked',
          'large', 'local-neighbor', 'home-case/Downloads'):
    (f / d).mkdir(parents=True, exist_ok=True)
for name in ('local/ORBITreview.pdf', 'local/sub/ORBITdeep.pdf',
             'outside/ORBIT', 'local/.ORBIT-secret', 'local/.hidden/ORBIThidden.pdf',
             'local/node_modules/deep/ORBITnoise', 'local/.cache/deep/ORBITnoise',
             'local/.git/deep/ORBITnoise', 'local/.pnpm/deep/ORBITnoise',
             'local/.cargo/deep/ORBITnoise', 'local/.rustup/deep/ORBITnoise'):
    (f / name).write_text('fixture needle\n')
for i in range(205):
    (f / 'many' / f'ORBIT-{i:03}.txt').write_text('fixture\n')
for i in range(200):
    (f / 'exactly' / f'ORBIT-{i:03}.txt').write_text('fixture\n')
# Deliberately create the best match after the cap, to test native top-K ranking.
for i in range(205):
    (f / 'ranked' / f'z-ORBIT-{i:03}.txt').write_text('fixture\n')
(f / 'ranked' / 'ORBIT').write_text('fixture\n')
for i in range(512):
    (f / 'large' / f'unrelated-{i:05}.txt').touch()
(f / 'large' / 'ORBIT-fresh.pdf').write_text('fixture\n')
(f / 'local' / 'content.txt').write_text('one\nfixture needle here\n')
(f / 'local' / 'binary.dat').write_bytes(b'\x00fixture needle')
(f / 'home-case' / 'ORBITreview.pdf').write_text('newly saved\n')
(f / 'home-case' / 'Downloads' / 'ORBITreview.pdf').write_text('newly saved\n')
(f / 'local' / 'outside-link').symlink_to('../outside', target_is_directory=True)
# Paths in script output refer to the sandbox HOME, never the real fixture path.
output = 'printf "file\\t%s/hybrid-fixture/outside/ORBIT\\n" "$HOME"\n'
for name, body in {
    'fast.sh': output,
    'selection.sh': 'sleep 0.4\nprintf "file\\t%s/hybrid-fixture/local/ORBIT\\n" "$HOME"\n' + output,
    'slow.sh': 'sleep 0.4\n' + output,
    'stubborn.sh': "trap '' TERM\nsleep 1\n" + output,
    'duplicates.sh': output + 'printf "file\\t%s/hybrid-fixture/local/ORBITreview.pdf\\nfile\\t%s/hybrid-fixture/local/ORBITreview.pdf\\n" "$HOME" "$HOME"\n',
    'none.sh': 'exit 2\n',
    'error.sh': 'exit 1\n',
    'empty.sh': 'exit 0\n',
    'many.sh': 'for i in $(seq -w 0 204); do printf "file\\t%s/hybrid-fixture/many/ORBIT-%s.txt\\n" "$HOME" "$i"; done\n',
    'exactly-duplicates.sh': 'for n in 1 2; do for i in $(seq -w 0 199); do printf "file\\t%s/hybrid-fixture/exactly/ORBIT-%s.txt\\n" "$HOME" "$i"; done; done\n',
    'query.sh': 'sleep 0.2\nprintf "file\\t%s/hybrid-fixture/outside/%s\\n" "$HOME" "$1"\n',
    'scope.sh': 'printf "file\\t%s/hybrid-fixture/local-neighbor/ORBIT\\nfile\\t%s/hybrid-fixture/local/sub/ORBITdeep.pdf\\nfile\\t%s/hybrid-fixture/local/ORBITreview.pdf\\n" "$HOME" "$HOME" "$HOME"\n',
}.items():
    script = f / name
    script.write_text('#!/usr/bin/env bash\n' + body)
    script.chmod(0o700)
real_home = Path.home()
cmd = ['bwrap', '--unshare-all', '--die-with-parent', '--ro-bind', '/', '/',
       '--bind', str(home), str(real_home), '--dev', '/dev', '--proc', '/proc',
       '--tmpfs', '/run', '--dir', f'/run/user/{os.getuid()}',
       '--bind', str(tmp), '/tmp']
# Re-expose only required trees after masking the real home, all read-only.
for p in dict.fromkeys((source, build, Path(__file__).resolve().parent)):
    cmd += ['--ro-bind', str(p), str(p)]
cmd += ['--chdir', str(real_home)]
for key, value in {
    'HOME': str(real_home), 'XDG_CONFIG_HOME': str(real_home / '.config'),
    'XDG_DATA_HOME': str(real_home / '.local/share'),
    'XDG_STATE_HOME': str(real_home / '.local/state'),
    'XDG_CACHE_HOME': str(real_home / '.cache'),
    'XDG_RUNTIME_DIR': f'/run/user/{os.getuid()}', 'TMPDIR': '/tmp',
    'QT_QPA_PLATFORM': 'offscreen', 'QT_QPA_PLATFORMTHEME': '',
    'QSG_RHI_BACKEND': 'software', 'QML_IMPORT_PATH': str(build / 'qml'),
}.items():
    cmd += ['--setenv', key, value]
for key in ('DBUS_SESSION_BUS_ADDRESS', 'DBUS_SYSTEM_BUS_ADDRESS', 'DISPLAY',
            'WAYLAND_DISPLAY', 'QML2_IMPORT_PATH'):
    cmd += ['--unsetenv', key]
if a.selfcheck:
    cmd += [str(build / 'omafiles-standalone'), '--selfcheck']
elif a.native:
    cmd += [str(build / 'search-worker-tests'), '-v1'] + a.cases
else:
    cmd += [str(build / 'hybrid-search-qml-tests'), '-input',
            str(Path(__file__).resolve().parent / 'tst_HybridSearch.qml'),
            '-import', str(build / 'qml'), '-v1'] + a.cases
import shlex
(evidence / 'command.txt').write_text(shlex.join(cmd) + '\n')
result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, timeout=240)
(evidence / 'output.log').write_text(result.stdout)
(evidence / 'exit-code.txt').write_text(str(result.returncode) + '\n')
sys.stdout.write(result.stdout)
print(f'Evidence: {evidence}; exit={result.returncode}')
sys.exit(result.returncode)
