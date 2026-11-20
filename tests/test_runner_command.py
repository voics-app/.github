"""Exercise runner pool selection with fake gh/docker commands, without touching runners."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

def shell_path(path):
    value = pathlib.Path(path).as_posix()
    return f"/{value[0].lower()}{value[2:]}" if os.name == 'nt' else value

class RunnerCommandTest(unittest.TestCase):
    def run_command(self, args, subset=None):
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d)
            (path / 'gh').write_text("""#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [[ "$1 $2" == 'api --paginate' ]]; then echo '{"name":"other","status":"online","labels":[{"name":"vm-runner"}]}'; fi
if [[ "$1" == api && "$2" == *variables/CI_RUNNER ]]; then echo vm-runner; fi
""")
            (path / 'docker').write_text('#!/usr/bin/env bash\nexit 0\n')
            for file in (path / 'gh', path / 'docker'):
                file.write_bytes(file.read_text().encode())
                file.chmod(0o755)
            env = {**os.environ, 'PATH': str(path) + os.pathsep + os.environ['PATH'], 'CALLS': shell_path(path / 'calls')}
            if subset is not None: env['SELF_HOSTED_REPOS'] = subset
            else: env.pop('SELF_HOSTED_REPOS', None)
            run = subprocess.run(['bash', shell_path(ROOT / 'scripts/runner.sh'), *args], env=env, capture_output=True, text=True)
            return run, (path / 'calls').read_text() if (path / 'calls').exists() else ''

    def test_use_targets_all_repositories_or_explicit_subset(self):
        run, calls = self.run_command(['use', 'vm-runner'])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(calls.count('variable set CI_RUNNER'), 12)
        run, calls = self.run_command(['use', 'vm-runner'], 'api client')
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(calls.count('variable set CI_RUNNER'), 2)

    def test_hosted_choice_and_down_never_switch_to_hosted(self):
        run, calls = self.run_command(['use', 'github'])
        self.assertNotEqual(run.returncode, 0)
        self.assertNotIn('variable delete', calls)
        run, calls = self.run_command(['down', '--label', 'vm-runner'])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn('variable delete', calls)
        self.assertNotIn('variable set', calls)
