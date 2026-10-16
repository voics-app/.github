"""Behavioural tests for the scripts embedded in the reusable workflows.

Each test extracts a step's `run:` block from the workflow YAML and executes
it the way the runner does (bash -eo pipefail, or python for `shell: python`),
with GITHUB_OUTPUT / GITHUB_ENV / GITHUB_STEP_SUMMARY pointing at temp files.
Requires: python3 with PyYAML, bash, jq.
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

import yaml

WORKFLOWS = pathlib.Path(__file__).resolve().parent.parent / ".github" / "workflows"


def load_step(workflow, job, step_id):
    with (WORKFLOWS / workflow).open(encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    for step in doc["jobs"][job]["steps"]:
        if step.get("id") == step_id:
            return step
    raise KeyError(f"{workflow}:{job}:{step_id}")


def parse_outputs(text):
    outputs, lines = {}, iter(text.splitlines())
    for line in lines:
        if "<<" in line and "=" not in line.split("<<", 1)[0]:
            name, delimiter = line.split("<<", 1)
            values = []
            for value in lines:
                if value == delimiter:
                    break
                values.append(value)
            outputs[name] = "\n".join(values)
        elif "=" in line:
            name, value = line.split("=", 1)
            outputs[name] = value
    return outputs


class StepRun:
    def __init__(self, result, outputs, summary):
        self.returncode = result.returncode
        self.stdout = result.stdout
        self.stderr = result.stderr
        self.outputs = outputs
        self.summary = summary


def run_step(step, env, cwd, path_prefix=None):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        files = {name: tmp / name for name in ("output", "env", "summary")}
        for file in files.values():
            file.touch()
        script = tmp / "script"
        script.write_text(step["run"], encoding="utf-8")
        full_env = {
            "PATH": os.environ["PATH"],
            "HOME": os.environ.get("HOME", str(tmp)),
            "GITHUB_OUTPUT": str(files["output"]),
            "GITHUB_ENV": str(files["env"]),
            "GITHUB_STEP_SUMMARY": str(files["summary"]),
            **env,
        }
        if path_prefix:
            full_env["PATH"] = f"{path_prefix}{os.pathsep}{full_env['PATH']}"
        if step.get("shell") == "python":
            command = [sys.executable, str(script)]
        else:
            command = ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)]
        result = subprocess.run(command, cwd=cwd, env=full_env, capture_output=True, text=True)
        return StepRun(
            result,
            parse_outputs(files["output"].read_text(encoding="utf-8")),
            files["summary"].read_text(encoding="utf-8"),
        )


class DockerMetaTest(unittest.TestCase):
    STEP = load_step("docker.yml", "image", "meta")

    def meta(self, ref, event="push", version="", push="true", manifest="0.1.0"):
        with tempfile.TemporaryDirectory() as repo:
            if manifest is not None:
                pathlib.Path(repo, ".release-please-manifest.json").write_text(json.dumps({".": manifest}))
            return run_step(
                self.STEP,
                {
                    "REF": ref,
                    "EVENT_NAME": event,
                    "RUN_NUMBER": "42",
                    "SHA": "abc123",
                    "SOURCE_URL": "https://github.com/discordy-voics/api",
                    "OWNER": "Discordy-Voics",
                    "REGISTRY": "ghcr.io",
                    "IMAGE_NAME": "api",
                    "DESCRIPTION": "Discordy REST API",
                    "VERSION_OVERRIDE": version,
                    "MANIFEST_PATH": ".release-please-manifest.json",
                    "MANIFEST_KEY": ".",
                    "PUSH_ENABLED": push,
                },
                cwd=repo,
            )

    def assert_tags(self, run, version, tags, publish):
        self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
        self.assertEqual(run.outputs["version"], version)
        self.assertEqual(run.outputs["tags"].splitlines(), [f"ghcr.io/discordy-voics/api:{t}" for t in tags])
        self.assertEqual(run.outputs["publish"], publish)

    def test_develop_publishes_dev_prerelease(self):
        self.assert_tags(self.meta("refs/heads/develop"), "0.1.0-dev.42", ["0.1.0-dev.42"], "true")

    def test_release_branch_with_version_uses_branch_version(self):
        self.assert_tags(self.meta("refs/heads/release/0.2.0"), "0.2.0-rc.42", ["0.2.0-rc.42"], "true")

    def test_release_branch_without_version_uses_manifest(self):
        self.assert_tags(self.meta("refs/heads/release/next"), "0.1.0-rc.42", ["0.1.0-rc.42"], "true")

    def test_hotfix_branch_publishes_release_candidate(self):
        self.assert_tags(self.meta("refs/heads/hotfix/0.1.1"), "0.1.1-rc.42", ["0.1.1-rc.42"], "true")

    def test_stable_tag_publishes_version_minor_and_latest(self):
        self.assert_tags(self.meta("refs/tags/v1.2.3"), "1.2.3", ["1.2.3", "1.2", "latest"], "true")

    def test_prerelease_tag_publishes_only_itself(self):
        self.assert_tags(self.meta("refs/tags/v1.3.0-beta.1"), "1.3.0-beta.1", ["1.3.0-beta.1"], "true")

    def test_version_override_publishes_stable(self):
        run = self.meta("refs/heads/main", version="v0.4.0")
        self.assert_tags(run, "0.4.0", ["0.4.0", "0.4", "latest"], "true")

    def test_feature_branch_is_never_pushed(self):
        self.assert_tags(self.meta("refs/heads/feature/api-x"), "0.1.0-ci.42", ["0.1.0-ci.42"], "false")

    def test_pull_request_is_never_pushed(self):
        run = self.meta("refs/heads/develop", event="pull_request")
        self.assertEqual(run.outputs["publish"], "false")

    def test_push_disabled_is_never_pushed(self):
        self.assertEqual(self.meta("refs/heads/develop", push="false").outputs["publish"], "false")

    def test_oci_labels(self):
        labels = dict(line.split("=", 1) for line in self.meta("refs/tags/v1.2.3").outputs["labels"].splitlines())
        self.assertEqual(labels["org.opencontainers.image.title"], "api")
        self.assertEqual(labels["org.opencontainers.image.description"], "Discordy REST API")
        self.assertEqual(labels["org.opencontainers.image.source"], "https://github.com/discordy-voics/api")
        self.assertEqual(labels["org.opencontainers.image.version"], "1.2.3")
        self.assertEqual(labels["org.opencontainers.image.revision"], "abc123")
        self.assertEqual(labels["org.opencontainers.image.licenses"], "UNLICENSED")

    def test_missing_manifest_fails(self):
        self.assertNotEqual(self.meta("refs/heads/develop", manifest=None).returncode, 0)

    def test_invalid_override_fails(self):
        self.assertNotEqual(self.meta("refs/heads/main", version="latest").returncode, 0)


class GitflowGuardTest(unittest.TestCase):
    STEP = load_step("gitflow-guard.yml", "gitflow", "check")

    def guard(self, head, base, event="pull_request"):
        return run_step(
            self.STEP,
            {
                "EVENT_NAME": event,
                "BASE_REF": base,
                "HEAD_REF": head,
                "MAIN_BRANCH": "main",
                "DEVELOP_BRANCH": "develop",
                "MAIN_SOURCES": "release/* hotfix/* release-please--*",
                "DEVELOP_SOURCES": "feature/* release/* hotfix/* dependabot/*",
            },
            cwd=tempfile.gettempdir(),
        ).returncode

    def test_allowed_pull_requests(self):
        for head, base in [
            ("release/0.1.0", "main"),
            ("hotfix/0.1.1", "main"),
            ("release-please--branches--main", "main"),
            ("feature/api-bootstrap", "develop"),
            ("release/0.1.0", "develop"),
            ("hotfix/0.1.1", "develop"),
            ("dependabot/cargo/serde-1.0.300", "develop"),
            ("feature/x", "release/0.1.0"),
        ]:
            with self.subTest(head=head, base=base):
                self.assertEqual(self.guard(head, base), 0)

    def test_rejected_pull_requests(self):
        for head, base in [
            ("feature/api-bootstrap", "main"),
            ("develop", "main"),
            ("dependabot/npm/x", "main"),
            ("main", "develop"),
            ("bugfix/x", "develop"),
            ("featurex", "develop"),
        ]:
            with self.subTest(head=head, base=base):
                self.assertEqual(self.guard(head, base), 1)

    def test_non_pull_request_events_pass(self):
        self.assertEqual(self.guard("", "", event="push"), 0)


class SecretsInventoryTest(unittest.TestCase):
    STEP = load_step("secrets-inventory-check.yml", "inventory", "check")

    DEPLOYMENT = """\
        apiVersion: apps/v1
        kind: Deployment
        metadata: {name: api}
        spec:
          template:
            spec:
              containers:
                - name: api
                  env:
                    - name: DATABASE_URL
                      valueFrom:
                        secretKeyRef: {name: api, key: DATABASE_URL}
        ---
        apiVersion: external-secrets.io/v1
        kind: ExternalSecret
        metadata: {name: api}
        spec:
          data:
            - secretKey: JWT_PRIVATE_KEY
              remoteRef: {key: discordy/api, property: JWT_PRIVATE_KEY}
        """

    def check(self, inventory, manifests):
        with tempfile.TemporaryDirectory() as work:
            work = pathlib.Path(work)
            (work / "inventory" / "secrets").mkdir(parents=True)
            (work / "inventory" / "secrets" / "inventory.yaml").write_text(textwrap.dedent(inventory))
            for name, content in manifests.items():
                path = work / "manifests" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(textwrap.dedent(content))
            return run_step(
                self.STEP,
                {
                    "INVENTORY_FILE": "inventory/secrets/inventory.yaml",
                    "MANIFESTS_DIR": "manifests/.",
                    "CHECKOUT_DIR": "manifests",
                },
                cwd=work,
            )

    def test_passes_when_every_key_is_listed(self):
        inventory = """\
            secrets:
              - name: DATABASE_URL
                services: [api]
              - name: JWT_PRIVATE_KEY
                services: [api]
            """
        run = self.check(inventory, {"apps/api/deployment.yaml": self.DEPLOYMENT})
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("2 reference(s) checked, 0 missing", run.summary)

    def test_fails_and_names_the_unlisted_key(self):
        inventory = """\
            api:
              DATABASE_URL: Postgres connection string
            """
        run = self.check(inventory, {"apps/api/deployment.yaml": self.DEPLOYMENT})
        self.assertEqual(run.returncode, 1)
        self.assertIn("::error file=apps/api/deployment.yaml", run.stdout)
        self.assertIn("'JWT_PRIVATE_KEY' is not listed", run.stdout)
        self.assertNotIn("'DATABASE_URL' is not listed", run.stdout)

    def test_templates_and_skipped_dirs_are_ignored(self):
        manifests = {
            "chart/templates/secret.yaml": "key: {{ .Values.x }}\n  bad: [\n",
            "node_modules/pkg/deploy.yaml": self.DEPLOYMENT,
        }
        run = self.check("secrets: []\n", manifests)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("::warning file=", run.stdout)

    def test_missing_inventory_fails(self):
        with tempfile.TemporaryDirectory() as work:
            run = run_step(
                self.STEP,
                {"INVENTORY_FILE": "nope.yaml", "MANIFESTS_DIR": ".", "CHECKOUT_DIR": "."},
                cwd=work,
            )
        self.assertEqual(run.returncode, 1)


class GhcrRetentionTest(unittest.TestCase):
    STEP = load_step("ghcr-retention.yml", "retention", "prune")

    FAKE_GH = """\
        #!/usr/bin/env bash
        if [[ "$1 $2" == "api -X" ]]; then
          echo "$4" >> "$FAKE_GH_LOG"
        else
          cat "$FAKE_GH_VERSIONS"
        fi
        """

    @staticmethod
    def version(vid, day, *tags):
        return {
            "id": vid,
            "name": f"sha256:d{vid}",
            "created_at": f"2026-10-{day:02d}T00:00:00Z",
            "metadata": {"container": {"tags": list(tags)}},
        }

    def prune(self, versions, dry_run="false", keep="5"):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            gh = tmp / "bin" / "gh"
            gh.parent.mkdir()
            gh.write_text(textwrap.dedent(self.FAKE_GH))
            gh.chmod(0o755)
            log = tmp / "deleted.log"
            log.touch()
            (tmp / "versions.json").write_text(json.dumps(versions))
            run = run_step(
                self.STEP,
                {
                    "GH_TOKEN": "x",
                    "OWNER": "discordy-voics",
                    "PACKAGES": "api",
                    "KEEP": keep,
                    "DRY_RUN": dry_run,
                    "FAKE_GH_LOG": str(log),
                    "FAKE_GH_VERSIONS": str(tmp / "versions.json"),
                },
                cwd=tmp,
                path_prefix=str(gh.parent),
            )
            deleted = sorted(int(line.rsplit("/", 1)[1]) for line in log.read_text().splitlines())
            return run, deleted

    def fixture(self):
        versions = [
            self.version(1, 1, "0.1.0"),
            self.version(2, 2, "0.2.0", "0.2", "latest"),
            self.version(3, 3),  # untagged platform manifest
            self.version(100, 4, "sha256-d4.sig"),  # signature of an expired prerelease
            self.version(101, 5, "sha256-d1.sig"),  # signature of a stable release
        ]
        versions += [self.version(n, 3 + n, f"0.3.0-dev.{n}") for n in range(4, 11)]  # 7 prereleases
        return versions

    def test_keeps_stable_and_newest_five_prereleases(self):
        run, deleted = self.prune(self.fixture())
        self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
        self.assertEqual(deleted, [4, 5, 100])
        self.assertEqual(run.outputs["deleted"], "3")

    def test_dry_run_deletes_nothing(self):
        run, deleted = self.prune(self.fixture(), dry_run="true")
        self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
        self.assertEqual(deleted, [])
        self.assertIn("would delete api version 4", run.stdout)

    def test_nothing_to_prune(self):
        run, deleted = self.prune([self.version(1, 1, "0.1.0-rc.1")])
        self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
        self.assertEqual(deleted, [])


if __name__ == "__main__":
    unittest.main()
