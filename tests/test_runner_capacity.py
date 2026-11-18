"""Run the real runner entrypoint with read-only Docker fixtures, never a daemon."""

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "runner.sh"
FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"
GIB = 1024**3


class RunnerCapacityTest(unittest.TestCase):
    def run_up(self, *, memory=8 * GIB, cpus=4, containers=(), args=(), dry_run=True,
               action="up", allow_startup=False, after_build=()):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            calls = directory / "calls"
            docker = directory / "docker"
            docker.write_text((FIXTURES / "runner-docker.sh").read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
            docker.chmod(0o755)
            gh = directory / "gh"
            gh.write_text((FIXTURES / "runner-gh.sh").read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
            gh.chmod(0o755)
            state = directory / "containers"
            state.write_text("".join(f"{name}\t{status}\n" for name, status in containers), encoding="utf-8", newline="\n")
            environment = {
                **os.environ,
                "PATH": f"{directory}{os.pathsep}{os.environ['PATH']}",
                "CALLS": calls.as_posix(),
                "CPU_FIXTURE": str(cpus),
                "MEMORY_FIXTURE": str(memory),
                "CONTAINERS_FILE": state.as_posix(),
                "PREFIX_FILE": (directory / "runner-prefix").as_posix(),
                "ALLOW_STARTUP": "1" if allow_startup else "0",
                "AFTER_BUILD_CONTAINERS": "".join(f"{name}\t{status}\n" for name, status in after_build),
            }
            command = [shutil.which("bash"), SCRIPT.as_posix(), action, "--label", "vm-runner", *args]
            if dry_run:
                command.append("--dry-run")
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
            recorded = calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []
            return result, recorded

    def assert_read_only(self, calls):
        self.assertTrue(calls)
        self.assertTrue(all(call.startswith(("docker info ", "docker ps ")) for call in calls), calls)

    def plan(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_eight_gib_defaults_to_one_runner(self):
        result, calls = self.run_up()
        plan = self.plan(result)
        self.assertEqual(plan["capacity"], 1)
        self.assertEqual(plan["desired"], 1)
        self.assertEqual(plan["start"], ["discordy-runner-vm-runner-1"])
        self.assert_read_only(calls)

    def test_twenty_four_gib_and_six_cpus_allow_three(self):
        result, calls = self.run_up(memory=24 * GIB, cpus=6)
        plan = self.plan(result)
        self.assertEqual(plan["capacity"], 3)
        self.assertEqual(len(plan["start"]), 3)
        self.assert_read_only(calls)

    def test_measured_seven_point_two_gib_vm_allows_one(self):
        result, _ = self.run_up(memory=int(7.2 * GIB))
        self.assertEqual(self.plan(result)["capacity"], 1)

    def test_cpu_budget_also_limits_large_memory_host(self):
        result, _ = self.run_up(memory=24 * GIB, cpus=2)
        self.assertEqual(self.plan(result)["capacity"], 1)

    def test_explicit_count_above_capacity_is_rejected_before_build(self):
        result, calls = self.run_up(args=("--count", "3"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("capacity", result.stderr.lower())
        self.assert_read_only(calls)

    def test_existing_number_two_satisfies_default_one(self):
        result, calls = self.run_up(containers=[("discordy-runner-vm-runner-2", "running")])
        plan = self.plan(result)
        self.assertEqual(plan["keep"], ["discordy-runner-vm-runner-2"])
        self.assertEqual(plan["start"], [])
        self.assert_read_only(calls)

    def test_real_up_with_number_two_is_a_read_only_noop(self):
        result, calls = self.run_up(
            containers=[("discordy-runner-vm-runner-2", "running")], dry_run=False
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nothing to start", result.stdout.lower())
        self.assert_read_only(calls)

    def test_other_labels_consume_the_same_host_budget(self):
        result, calls = self.run_up(
            containers=[("discordy-runner-other-pool-8", "running")], args=("--count", "1")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("capacity", result.stderr.lower())
        self.assert_read_only(calls)

    def test_paused_or_restarting_runners_still_reserve_resources(self):
        for state in ("paused", "restarting"):
            with self.subTest(state=state):
                result, calls = self.run_up(
                    containers=[("discordy-runner-other-pool-1", state)], args=("--count", "1")
                )
                self.assertNotEqual(result.returncode, 0)
                self.assert_read_only(calls)

    def test_existing_excess_is_reported_without_shrinking(self):
        result, calls = self.run_up(
            containers=[(f"discordy-runner-vm-runner-{i}", "running") for i in (1, 2, 3)]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("drain", result.stderr.lower())
        self.assert_read_only(calls)

    def test_explicit_smaller_count_does_not_remove_existing_runners(self):
        result, calls = self.run_up(
            memory=24 * GIB,
            cpus=6,
            containers=[(f"discordy-runner-vm-runner-{i}", "running") for i in (2, 3)],
            args=("--count", "1"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("drain", result.stderr.lower())
        self.assert_read_only(calls)

    def test_stopped_containers_are_preserved_without_recreate(self):
        result, calls = self.run_up(containers=[("discordy-runner-vm-runner-1", "exited")])
        self.assertEqual(self.plan(result)["start"], ["discordy-runner-vm-runner-2"])
        self.assert_read_only(calls)

    def test_explicit_recreate_plans_only_stopped_containers(self):
        result, calls = self.run_up(
            containers=[("discordy-runner-vm-runner-2", "exited")], args=("--recreate",)
        )
        plan = self.plan(result)
        self.assertEqual(plan["recreate"], ["discordy-runner-vm-runner-2"])
        self.assert_read_only(calls)

    def test_recreate_refuses_a_running_runner_even_when_capacity_fits(self):
        result, calls = self.run_up(
            containers=[("discordy-runner-vm-runner-2", "running")], args=("--recreate",)
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("drain", result.stderr.lower())
        self.assert_read_only(calls)

    def test_too_small_host_or_invalid_resource_response_fails_closed(self):
        for memory in (6 * GIB, "", "unknown"):
            with self.subTest(memory=memory):
                result, calls = self.run_up(memory=memory)
                self.assertNotEqual(result.returncode, 0)
                self.assert_read_only(calls)

    def test_invalid_count_never_reaches_docker(self):
        for count in ("0", "-1", "1;echo bad", "01", "1.5"):
            with self.subTest(count=count):
                result, calls = self.run_up(args=("--count", count))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_preflight_alias_is_read_only(self):
        result, calls = self.run_up(action="preflight", dry_run=False)
        self.assertEqual(self.plan(result)["desired"], 1)
        self.assert_read_only(calls)

    def test_dry_run_on_down_is_rejected_before_any_action(self):
        result, calls = self.run_up(action="down")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_up_starts_only_the_missing_total_and_keeps_number_two(self):
        result, calls = self.run_up(
            memory=24 * GIB, cpus=6, dry_run=False, allow_startup=True,
            containers=[("discordy-runner-vm-runner-2", "running")], args=("--count", "2"),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        starts = [call for call in calls if call.startswith("docker run ")]
        self.assertEqual(len(starts), 1, calls)
        self.assertIn("--name discordy-runner-vm-runner-1 ", starts[0])
        self.assertFalse(any(call.startswith("docker rm ") for call in calls))

    def test_startup_rechecks_other_labels_after_image_preparation(self):
        result, calls = self.run_up(
            dry_run=False, allow_startup=True,
            after_build=[("discordy-runner-other-pool-8", "running")],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("capacity", result.stderr.lower())
        self.assertTrue(any(call.startswith("docker build ") for call in calls))
        self.assertFalse(any(call.startswith(("docker run ", "docker rm ", "gh ")) for call in calls))

    def test_recreate_replaces_each_stopped_runner_without_force(self):
        result, calls = self.run_up(
            memory=24 * GIB, cpus=6, dry_run=False, allow_startup=True,
            containers=[(f"discordy-runner-vm-runner-{i}", "exited") for i in (1, 2, 3)],
            args=("--recreate",),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([call for call in calls if call.startswith("docker rm ")], [
            f"docker rm discordy-runner-vm-runner-{i}" for i in (1, 2, 3)
        ])
        self.assertEqual(len([call for call in calls if call.startswith("docker run ")]), 3)


if __name__ == "__main__":
    unittest.main()
