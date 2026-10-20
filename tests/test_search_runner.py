"""Portable runner setup tests; subprocess execution is intercepted, never selfcheck."""
import contextlib
import io
import os
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


RUNNER = Path(__file__).resolve().with_name('run-search-tests.py')


class SearchRunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='omafiles-runner-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.temp = self.root / 'portable tmp'
        self.temp.mkdir()
        self.build = self.root / 'build'
        self.build.mkdir()

    def invoke(self, evidence, *mode, execution_error=None):
        argv = [str(RUNNER), '--build', str(self.build),
                '--evidence', str(evidence), *mode]
        output = io.StringIO()
        with patch.object(sys, 'argv', argv), \
                patch.dict(os.environ, {'TMPDIR': str(self.temp)}), \
                patch.object(tempfile, 'tempdir', None), \
                patch('subprocess.run', return_value=subprocess.CompletedProcess(
                    [], 0, 'intercepted sandbox command\n'),
                    side_effect=execution_error) as execute, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.execution = execute
            try:
                runpy.run_path(str(RUNNER), run_name='__main__')
            except SystemExit as exit:
                return exit.code, execute, output.getvalue()
        self.fail('runner must exit with the sandbox result')

    def test_tmpdir_selects_evidence_parent_and_preserves_isolation(self):
        evidence = self.temp / 'qml-evidence'
        code, execute, output = self.invoke(evidence)
        self.assertEqual(code, 0, output)
        command = execute.call_args.args[0]
        self.assertEqual(command[0], 'bwrap')
        self.assertIn('--unshare-all', command)
        self.assertIn('--die-with-parent', command)
        i = command.index('--ro-bind')
        self.assertEqual(command[i:i + 3], ['--ro-bind', '/', '/'])
        for source, target in ((evidence / 'home', Path.home()),
                               (evidence / 'tmp', Path('/tmp'))):
            i = command.index(str(source))
            self.assertEqual(command[i - 1:i + 2], ['--bind', str(source), str(target)])
        for key in ('DBUS_SESSION_BUS_ADDRESS', 'DBUS_SYSTEM_BUS_ADDRESS',
                    'DISPLAY', 'WAYLAND_DISPLAY'):
            i = command.index(key)
            self.assertEqual(command[i - 1], '--unsetenv')
        self.assertIn('--tmpfs', command)
        self.assertIn(str(self.build / 'hybrid-search-qml-tests'), command)
        self.assertEqual(shlex.split((evidence / 'command.txt').read_text()), command)
        self.assertTrue((evidence / 'home/.local/share/Trash/files').is_dir())
        self.assertEqual((evidence / 'exit-code.txt').read_text(), '0\n')

    def test_native_and_selfcheck_still_use_sandbox(self):
        for flag, executable in (('--native', 'search-worker-tests'),
                                 ('--selfcheck', 'omafiles-standalone')):
            with self.subTest(mode=flag):
                code, execute, output = self.invoke(self.temp / executable, flag)
                self.assertEqual(code, 0, output)
                command = execute.call_args.args[0]
                self.assertEqual(command[0], 'bwrap')
                self.assertIn(str(self.build / executable), command)

    def test_rejects_evidence_outside_temp_before_writing(self):
        evidence = self.root / 'outside'
        code, execute, _ = self.invoke(evidence)
        self.assertEqual(code, 2)
        execute.assert_not_called()
        self.assertFalse(evidence.exists())

    def test_rejects_symlink_escape_before_writing(self):
        (self.temp / 'escape').symlink_to(self.root, target_is_directory=True)
        evidence = self.temp / 'escape/outside'
        code, execute, _ = self.invoke(evidence)
        self.assertEqual(code, 2)
        execute.assert_not_called()
        self.assertFalse(evidence.exists())

    def test_missing_bwrap_has_no_unsandboxed_fallback(self):
        with self.assertRaises(FileNotFoundError):
            self.invoke(self.temp / 'missing-bwrap', '--selfcheck',
                        execution_error=FileNotFoundError('bwrap unavailable'))
        self.execution.assert_called_once()
        self.assertEqual(self.execution.call_args.args[0][0], 'bwrap')


if __name__ == '__main__':
    unittest.main()
