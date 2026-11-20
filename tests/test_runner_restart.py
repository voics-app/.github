"""Exercise container entrypoint with disposable runner files; no Docker or GitHub."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASH = (r"C:\Program Files\Git\usr\bin\bash.exe" if os.name == "nt" else shutil.which("bash"))


def shell_path(path):
    value = pathlib.Path(path).as_posix()
    return f"/{value[0].lower()}{value[2:]}" if os.name == "nt" else value


class RunnerRestartTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name)
        self.script("config.sh", """printf 'config\n' >> calls
: > .runner; : > .credentials; : > .credentials_rsaparams
""")
        self.script("run.sh", """test -z "${REG_TOKEN+x}" || exit 5
printf 'run\n' >> calls
""")
        self.env = {**os.environ, "RUNNER_HOME": shell_path(self.home),
                    "REG_TOKEN": "synthetic-secret", "ORG": "fixture", "NAME": "fixture",
                    "LABEL": "fixture", "WORK": "/tmp/fixture"}
        if os.name == "nt":
            # Git for Windows lacks flock. Linux CI exercises the real command.
            shim = self.home / "bash-env"
            shim.write_text("flock() { return 0; }\n")
            self.env["BASH_ENV"] = shell_path(shim)
            self.env["PATH"] = r"C:\Program Files\Git\bin" + os.pathsep + os.environ["PATH"]

    def script(self, name, contents):
        path = self.home / name
        path.write_bytes(("#!/usr/bin/env bash\n" + contents).encode())
        path.chmod(0o755)

    def start(self):
        return subprocess.run([BASH, shell_path(ROOT / "scripts/runner-entrypoint.sh")],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def test_initial_start_and_real_restart_reuse_registration(self):
        first = self.start()
        second = self.start()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((self.home / "calls").read_text().splitlines(), ["config", "run", "run"])
        self.assertNotIn("synthetic-secret", first.stdout + first.stderr + second.stdout + second.stderr)

    def test_partial_registration_fails_closed(self):
        (self.home / ".runner").touch()
        result = self.start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete runner registration", result.stderr)
        self.assertFalse((self.home / "calls").exists())

    @unittest.skipIf(os.name == "nt", "requires Linux flock")
    def test_second_listener_is_rejected(self):
        import fcntl
        with (self.home / ".discordy-listener.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runner listener already active", result.stderr)
        self.assertFalse((self.home / "calls").exists())

    def test_registration_must_produce_credentials(self):
        self.script("config.sh", "exit 0\n")
        result = self.start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runner registration did not complete", result.stderr)
        self.assertFalse((self.home / "calls").exists())

    def test_container_configuration_and_pool_failure_are_explicit(self):
        helper = (ROOT / "scripts/runner.sh").read_text()
        self.assertIn("--restart unless-stopped", helper)
        self.assertIn("docker container inspect", helper)
        self.assertIn("not all requested runners registered", helper)
        self.assertNotIn('docker rm -f "$c" >/dev/null 2>&1 || true', helper)

if __name__ == "__main__":
    unittest.main()
