"""Keep default Linux jobs on VM runners even when legacy variables name GitHub."""
import pathlib
import unittest
import yaml

WORKFLOWS = pathlib.Path(__file__).resolve().parent.parent / ".github" / "workflows"

class RunnerRoutingTest(unittest.TestCase):
    def test_linux_jobs_do_not_fall_back_to_hosted(self):
        for name in ("node.yml", "rust.yml", "elixir.yml", "docker.yml", "gitflow-guard.yml", "release-please.yml", "ghcr-retention.yml", "secrets-inventory-check.yml"):
            jobs = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))["jobs"]
            for job in jobs.values():
                if "runs-on" in job:
                    with self.subTest(workflow=name, job=job.get("name")):
                        self.assertIn("'vm-runner'", job["runs-on"])
                        self.assertNotIn("|| 'ubuntu-latest'", job["runs-on"])
        for name in ("ci.yml", "cache-cleanup.yml"):
            jobs = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))["jobs"]
            for job in jobs.values():
                if "runs-on" in job:
                    self.assertIn("vm-runner", job["runs-on"])

    def test_rust_runs_combined_check_for_default_and_arc_remains_isolated(self):
        rust = yaml.safe_load((WORKFLOWS / "rust.yml").read_text(encoding="utf-8"))["jobs"]
        self.assertNotIn("CI_RUNNER", rust["check"]["if"])
        self.assertFalse({"fmt", "clippy", "test"} & set(rust))
        publish = yaml.safe_load((WORKFLOWS / "minio-publish.yml").read_text(encoding="utf-8"))["jobs"]
        self.assertEqual(publish["publish"]["runs-on"], "discordy")
