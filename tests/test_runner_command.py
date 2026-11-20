"""Exercise runner pool selection with fake gh/docker commands, without touching runners."""
import os
import pathlib
import subprocess
import shutil
import tempfile
import unittest
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASH = (r"C:\Program Files\Git\usr\bin\bash.exe" if os.name == "nt" else shutil.which("bash"))

def shell_path(path):
    value = pathlib.Path(path).as_posix()
    return f"/{value[0].lower()}{value[2:]}" if os.name == 'nt' else value

class RunnerCommandTest(unittest.TestCase):
    def run_command(self, args, subset=None, windows_gh_crlf=False):
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d)
            real_jq = shutil.which('jq')
            if os.name == 'nt' and real_jq is None:
                packages = pathlib.Path(os.environ['LOCALAPPDATA']) / 'Microsoft' / 'WinGet' / 'Packages'
                real_jq = str(next(packages.glob('jqlang.jq_*/jq.exe')))
            (path / 'gh').write_text("""#!/usr/bin/env bash
printf '%q ' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"
if [[ "$1 $2 $3" == 'api -X DELETE' && "${!#}" == *$'\r'* ]]; then
  printf 'invalid control character in runner id\n' >> "$CALLS"
  exit 42
fi
if [[ "$1 $2" == 'api --paginate' ]]; then
  if [[ "${WINDOWS_GH_CRLF:-}" == 1 ]]; then
    if [[ -r /etc/machine-id ]]; then
      node="$(tr -dc 'a-z0-9' </etc/machine-id | cut -c1-6)"
    else
      node="$(hostname | tr 'A-Z' 'a-z' | tr -dc 'a-z0-9' | cut -c1-6)"
    fi
    printf '{"id":267,"name":"fixture-%s-1","status":"offline","labels":[{"name":"fixture"}]}\r\n' "$node"
  else
    echo '{"name":"other","status":"online","labels":[{"name":"vm-runner"}]}'
  fi
fi
if [[ "$1" == api && "$2" == *variables/CI_RUNNER ]]; then echo vm-runner; fi
""")
            (path / 'docker').write_text('#!/usr/bin/env bash\nexit 0\n')
            (path / 'jq-shim.py').write_text("""import os
import subprocess
import sys

if os.environ.get('WINDOWS_GH_CRLF') == '1' and any('.id' in arg for arg in sys.argv[1:]):
    sys.stdin.buffer.read()
    # Keep CR non-terminal through Git Bash; word splitting removes the space.
    sys.stdout.buffer.write(b'267\\r ')
    raise SystemExit(0)
raise SystemExit(subprocess.call([os.environ['REAL_JQ_NATIVE'], *sys.argv[1:]]))
""")
            (path / 'jq').write_text("""#!/usr/bin/env bash
exec "$REAL_PYTHON" "$JQ_SHIM" "$@"
""")
            for file in (path / 'gh', path / 'docker', path / 'jq'):
                file.write_bytes(file.read_text().encode())
                file.chmod(0o755)
            command_path = (shell_path(path) + ':/usr/bin:/bin' if os.name == 'nt'
                            else str(path) + os.pathsep + os.environ['PATH'])
            env = {**os.environ, 'PATH': command_path, 'CALLS': shell_path(path / 'calls'),
                   'REAL_JQ_NATIVE': real_jq, 'REAL_PYTHON': shell_path(sys.executable),
                   'JQ_SHIM': str(path / 'jq-shim.py')}
            if windows_gh_crlf: env['WINDOWS_GH_CRLF'] = '1'
            if subset is not None: env['SELF_HOSTED_REPOS'] = subset
            else: env.pop('SELF_HOSTED_REPOS', None)
            run = subprocess.run([BASH, shell_path(ROOT / 'scripts/runner.sh'), *args], env=env, capture_output=True, text=True)
            return run, (path / 'calls').read_text() if (path / 'calls').exists() else ''

    def test_use_targets_all_repositories_or_explicit_subset(self):
        run, calls = self.run_command(['use', 'vm-runner'])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(calls.count('variable set CI_RUNNER'), 12)
        run, calls = self.run_command(['use', 'vm-runner'], 'api client')
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(calls.count('variable set CI_RUNNER'), 2)

    def test_up_refuses_existing_container_before_registration_or_build(self):
        run, calls = self.run_command(['up', '--count', '1', '--label', 'fixture'])
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('already exists', run.stderr)
        self.assertNotIn('registration-token', calls)
        self.assertNotIn('variable set', calls)

    def test_hosted_choice_and_down_never_switch_to_hosted(self):
        run, calls = self.run_command(['use', 'github'])
        self.assertNotEqual(run.returncode, 0)
        self.assertNotIn('variable delete', calls)
        run, calls = self.run_command(['down', '--label', 'vm-runner'])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn('variable delete', calls)
        self.assertNotIn('variable set', calls)

    def test_down_strips_cr_from_windows_gh_runner_id(self):
        run, calls = self.run_command(['down', '--label', 'fixture'], windows_gh_crlf=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('api -X DELETE orgs/discordy-voics/actions/runners/267 ', calls)
        self.assertNotIn('invalid control character in runner id', calls)
