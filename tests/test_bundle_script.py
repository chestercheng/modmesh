# Copyright (c) 2026, solvcon team <contact@solvcon.net>
# BSD 3-Clause License, see COPYING

"""Check the bundle CLI and Mach-O parser without installing dependencies."""

import ast
import configparser
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest


SCRIPT = (pathlib.Path(__file__).resolve().parents[1]
          / 'contrib' / 'bundle' / 'bundle-with-prefix.sh')


@unittest.skipUnless(os.name == 'posix', 'requires a POSIX shell')
class BundleScriptTC(unittest.TestCase):
    """Keep CLI validation and static scans independent of a macOS SDK."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ)
        self.env.pop('AQT_CONFIG', None)
        self.env['PATH'] = str(self.bin) + os.pathsep + '/usr/bin:/bin'
        self._write_tool('uname', "printf '%s\\n' Linux\n")

    def _write_tool(self, name, body):
        """Stub the OS/tool boundary while running the real shell code."""
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body)
        path.chmod(0o755)

    def _run(self, *args):
        return subprocess.run(
            [str(SCRIPT), *args], cwd=self.root, env=self.env,
            capture_output=True, text=True, timeout=10)

    def _run_functions(self, body, *args):
        """Load canonical helpers, stopping before the CLI dispatch."""
        helpers, marker, _ = SCRIPT.read_text().partition(
            '\nCOMMAND=bundle\n')
        self.assertTrue(marker)
        return subprocess.run(
            ['/bin/bash', '-c', helpers + '\n' + body, str(SCRIPT), *args],
            cwd=self.root, env=self.env, capture_output=True, text=True,
            timeout=10)

    def _otool_fixture(self, loads, rpaths=''):
        """Supply Mach-O tool output without inspecting host libraries."""
        for name, content in (('loads', loads), ('rpaths', rpaths)):
            path = self.root / name
            path.write_text(content)
            self.env['BUNDLE_FIXTURE_' + name.upper()] = str(path)
        self._write_tool('otool', '''
if [[ "${BUNDLE_FIXTURE_FAIL:-}" == 1 ]]; then exit 23; fi
case "$1" in
    -L) /bin/cat "$BUNDLE_FIXTURE_LOADS" ;;
    -l) /bin/cat "$BUNDLE_FIXTURE_RPATHS" ;;
    *) exit 24 ;;
esac
''')

    def test_help(self):
        result = self._run('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('prepare [--prefix DIR] [--tools-prefix DIR]',
                      result.stdout)

    def test_invalid_options(self):
        for args in (('check', '--prefix'), ('check', '--prefix', ''),
                     ('check', '--prefix', '/'),
                     ('check', '--tools-prefix'),
                     ('check', '--tools-prefix', '/'),
                     ('verify', 'artifact.dmg', '--tools-prefix', 'tools'),
                     ('check', '--dry-run'), ('verify',),
                     ('prepare', '--skip-build')):
            with self.subTest(args=args):
                result = self._run(*args)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_non_macos_guard_after_prefix_parsing(self):
        result = self._run('check', '--prefix', 'unused-prefix')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('macOS is required', result.stderr)
        self.assertNotIn('not found', result.stderr)
        self.assertFalse((self.root / 'unused-prefix').exists())

    def test_prepare_dry_run(self):
        self._write_tool('uname', '''
case "$1" in
    -s) printf '%s\\n' Darwin ;;
    -m) printf '%s\\n' arm64 ;;
    *) exit 25 ;;
esac
''')
        prefix = 'deps with spaces/6.11.1/macos'
        tools = 'tools with spaces'
        result = self._run('prepare', '--prefix', prefix,
                           '--tools-prefix', tools, '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.root / prefix), result.stdout)
        self.assertIn(str(self.root / tools), result.stdout)
        self.assertIn('install runtime packages', result.stdout)
        self.assertIn('Python 3.14.7 (aarch64)', result.stdout)
        self.assertIn('Qt 6.11.1', result.stdout)
        self.assertIn('SHA-256', result.stdout)
        self.assertIn('macOS system certificate store (pip-system-certs)',
                      result.stdout)
        config = SCRIPT.parents[2] / 'thirdparty' / 'aqt_settings.ini'
        self.assertIn('AQT_CONFIG="' + str(config) + '" ',
                      result.stdout)
        self.assertIn(str(self.root / tools / 'bin' / 'python3'),
                      result.stdout)
        self.assertFalse((self.root / 'deps with spaces').exists())
        self.assertFalse((self.root / tools).exists())

    def test_prepare_config_is_resolved_from_caller(self):
        self._write_tool('uname', '''
case "$1" in
    -s) printf '%s\\n' Darwin ;;
    -m) printf '%s\\n' arm64 ;;
    *) exit 25 ;;
esac
''')
        config = self.root / 'custom aqt.ini'
        config.write_text('[aqt]\nbaseurl: https://download.qt.io\n')
        self.env['AQT_CONFIG'] = config.name
        result = self._run('prepare', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('AQT_CONFIG="' + str(config) + '" ',
                      result.stdout)

    def test_prepare_rejects_overlapping_prefixes(self):
        self._write_tool('uname', "printf '%s\\n' Darwin\n")
        sdk = self.root / 'sdk' / '6.11.1' / 'macos'
        for tools in (sdk, sdk / 'tools', self.root / 'sdk'):
            with self.subTest(tools=tools):
                result = self._run('prepare', '--prefix', str(sdk),
                                   '--tools-prefix', str(tools))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('separate, non-nested', result.stderr)
                self.assertFalse(sdk.exists())

    def test_reject_mixed_sdk_without_removing_packages(self):
        sdk = self.root
        site = sdk / 'lib' / 'python3.14' / 'site-packages'
        metadata = site / 'cmake-4.4.3.dist-info'
        metadata.mkdir(parents=True)
        (metadata / 'METADATA').write_text('Name: cmake\nVersion: 4.4.3\n')
        self.env['BUNDLE_FIXTURE_SITE'] = str(site)
        self.env['BUNDLE_FIXTURE_PYTHON'] = sys.executable
        self._write_tool('python3', '''
exec "$BUNDLE_FIXTURE_PYTHON" -I -B -c '
import os, sys
sys.path.insert(0, os.environ["BUNDLE_FIXTURE_SITE"])
exec(sys.stdin.read())
'
''')
        result = self._run_functions(
            'PREFIX="$1"\ncheck_runtime_packages', str(sdk))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('SDK contains build-only packages', result.stderr)
        self.assertIn('cmake', result.stderr)
        self.assertTrue((metadata / 'METADATA').exists())

    def test_prepare_rejects_missing_config_before_download(self):
        self._write_tool('uname', "printf '%s\\n' Darwin\n")
        self.env['AQT_CONFIG'] = 'missing.ini'
        result = self._run('prepare', '--prefix', 'deps/6.11.1/macos')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('aqt settings file not found', result.stderr)
        self.assertFalse((self.root / 'deps').exists())

    def test_ci_config_excludes_failing_mirror(self):
        config = configparser.ConfigParser()
        config.read(SCRIPT.parents[2] / 'thirdparty' / 'aqt_settings.ini')
        host = 'ftp.yz.yamagata-u.ac.jp'
        blacklist = config.get('mirrors', 'blacklist').splitlines()
        self.assertIn('http://' + host, blacklist)
        self.assertIn('https://' + host, blacklist)
        self.assertNotIn(host, config.get('mirrors', 'fallbacks'))
        self.assertFalse(config.getboolean(
            'requests', 'INSECURE_NOT_FOR_PRODUCTION_ignore_hash'))

    def test_embedded_python_syntax(self):
        programs = re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY\b",
                              SCRIPT.read_text(), re.DOTALL)
        self.assertGreaterEqual(len(programs), 3)
        for program in programs:
            ast.parse(program)

    def test_rpaths_preserve_spaces_and_deduplicate_slices(self):
        entry = '''Load command 0
          cmd LC_RPATH
      cmdsize 64
         path /source deps/lib (offset 12)
'''
        self._otool_fixture('', entry + entry)
        result = self._run_functions('binary_rpaths "$1"', 'fixture')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '/source deps/lib\n')

    def test_static_scan_rejects_non_system_paths(self):
        self._otool_fixture('''fixture:
    /source deps/libbad.dylib (compatibility version 1.0.0)
    /usr/lib/libSystem.B.dylib (compatibility version 1.0.0)
''')
        app = self.root / 'pilot.app'
        app.mkdir()
        (app / 'libfixture.dylib').touch()
        result = self._run_functions('check_self_contained "$1"', str(app))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('/source deps/libbad.dylib', result.stdout)
        self.assertNotIn('OK:', result.stdout)

    def test_static_scan_propagates_tool_failure(self):
        self._otool_fixture('')
        self.env['BUNDLE_FIXTURE_FAIL'] = '1'
        app = self.root / 'pilot.app'
        app.mkdir()
        (app / 'libfixture.dylib').touch()
        result = self._run_functions('check_self_contained "$1"', str(app))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('OK:', result.stdout)

    def test_resolve_bundled_relative_rpath(self):
        self._otool_fixture('', '''Load command 0
          cmd LC_RPATH
      cmdsize 64
         path @loader_path/.dylibs (offset 12)
''')
        app = self.root / 'pilot.app'
        loader = app / 'Contents' / 'lib' / 'package' / 'module.so'
        library = loader.parent / '.dylibs' / 'libfixture.dylib'
        library.parent.mkdir(parents=True)
        library.touch()
        self.env['BUNDLE_FIXTURE_PYTHON'] = sys.executable
        self._write_tool('python3',
                         'exec "$BUNDLE_FIXTURE_PYTHON" "$@"\n')
        result = self._run_functions(
            'PREFIX="$2"\nAPP="$3"\nBINARY="$3/Contents/MacOS/pilot"\n'
            'resolve_rpath "$1" @rpath/libfixture.dylib',
            str(loader), str(self.root), str(app))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(library.resolve()))

    def test_runtime_scan_rejects_other_external_prefixes(self):
        app = self.root / 'pilot.app'
        binary = app / 'Contents' / 'MacOS' / 'pilot'
        binary.parent.mkdir(parents=True)
        trace = self.root / 'dyld.trace'
        trace.write_text(
            f'dyld[1]: <uuid> {binary}\n'
            'dyld[1]: <uuid> /usr/lib/libSystem.B.dylib\n'
            'dyld[1]: <uuid> /Library/Apple/System/Library/libsystem.dylib\n'
            'dyld[1]: <uuid> /Users/vendor/libexternal.dylib\n')
        result = self._run_functions(
            'external_runtime_loads "$1" "$2"', str(trace), str(binary))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '/Users/vendor/libexternal.dylib\n')


# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4 tw=79:
