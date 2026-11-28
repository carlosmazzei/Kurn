import tempfile
import textwrap
import unittest
from pathlib import Path

from Tools import check_workflow_security as security


def repository(workflows: dict[str, str], codeowners: str | None = "/.github/ @owner\n",
               actions: dict[str, str] | None = None) -> Path:
    root = Path(tempfile.mkdtemp())
    (root / ".github" / "workflows").mkdir(parents=True)
    for name, text in workflows.items():
        (root / ".github" / "workflows" / name).write_text(textwrap.dedent(text), encoding="utf-8")
    for name, text in (actions or {}).items():
        folder = root / ".github" / "actions" / name
        folder.mkdir(parents=True)
        (folder / "action.yml").write_text(textwrap.dedent(text), encoding="utf-8")
    if codeowners is not None:
        (root / ".github" / "CODEOWNERS").write_text(codeowners, encoding="utf-8")
    return root


PAID_JOB = """\
    name: eval
    on:
      workflow_dispatch:
    jobs:
      run:
        runs-on: macos-26
        {environment}
        steps:
          - run: echo
            env:
              KEY: ${{{{ secrets.OPENAI_API_KEY }}}}
    """


class WorkflowSecurityTests(unittest.TestCase):
    def test_the_repository_passes(self):
        self.assertEqual(security.check(), [])

    def test_a_paid_secret_in_its_environment_passes(self):
        root = repository({"eval.yml": PAID_JOB.format(environment="environment: paid-evals")})
        self.assertEqual(security.check(root), [])

    def test_a_paid_secret_without_the_environment_is_refused(self):
        root = repository({"eval.yml": PAID_JOB.format(environment="")})
        findings = security.check(root)
        self.assertEqual(len(findings), 1)
        self.assertIn("must declare `environment: paid-evals`", findings[0])
        self.assertIn("declares none", findings[0])

    def test_the_wrong_environment_is_refused_and_a_mapping_form_is_read(self):
        wrong = repository({"eval.yml": PAID_JOB.format(environment="environment: release")})
        self.assertIn("declares release", security.check(wrong)[0])
        mapping = repository({"eval.yml": PAID_JOB.format(environment="environment:\n          name: paid-evals")})
        self.assertEqual(security.check(mapping), [])

    def test_a_paid_secret_only_runs_on_demand(self):
        for trigger in ("push:", "pull_request:", "schedule:"):
            text = PAID_JOB.format(environment="environment: paid-evals").replace(
                "workflow_dispatch:", f"workflow_dispatch:\n      {trigger}")
            findings = security.check(repository({"eval.yml": text}))
            self.assertTrue(any("`workflow_dispatch` only" in finding for finding in findings), trigger)

    def test_release_secrets_need_the_release_environment(self):
        text = """\
            name: ship
            on:
              workflow_dispatch:
            jobs:
              upload:
                runs-on: ubuntu-latest
                {environment}
                steps:
                  - run: echo ${{{{ secrets.ASC_KEY_ID }}}}
            """
        self.assertEqual(security.check(repository({"ship.yml": text.format(environment="environment: release")})), [])
        self.assertEqual(len(security.check(repository({"ship.yml": text.format(environment="")}))), 1)

    def test_an_unclassified_secret_is_refused(self):
        text = PAID_JOB.format(environment="environment: paid-evals").replace("OPENAI_API_KEY", "NEW_VENDOR_KEY")
        findings = security.check(repository({"eval.yml": text}))
        self.assertIn("does not classify", findings[0])

    def test_free_secrets_need_nothing(self):
        text = """\
            name: ci
            on:
              pull_request:
              push:
            jobs:
              test:
                runs-on: ubuntu-latest
                steps:
                  - run: echo ${{ secrets.CODECOV_TOKEN }} ${{ secrets.GITHUB_TOKEN }}
            """
        self.assertEqual(security.check(repository({"ci.yml": text})), [])

    def test_a_secret_named_only_in_a_comment_is_ignored(self):
        text = "name: ci\non:\n  pull_request:\njobs:\n  test:\n    runs-on: x\n    steps:\n      # secrets.OPENAI_API_KEY\n      - run: echo\n"
        self.assertEqual(security.check(repository({"ci.yml": text})), [])

    def test_triggers_that_run_outsider_content_with_secrets_are_refused(self):
        for trigger in ("pull_request_target", "workflow_run", "issue_comment", "issues"):
            text = f"name: x\non:\n  {trigger}:\njobs:\n  test:\n    runs-on: x\n    steps:\n      - run: echo\n"
            findings = security.check(repository({"x.yml": text}))
            self.assertTrue(any(trigger in finding for finding in findings), trigger)

    def test_inherit_dynamic_access_and_inline_triggers_are_refused(self):
        inherit = "name: x\non:\n  push:\njobs:\n  call:\n    uses: ./.github/workflows/y.yml\n    secrets: inherit\n"
        self.assertIn("secrets: inherit", security.check(repository({"x.yml": inherit}))[0])
        dynamic = "name: x\non:\n  push:\njobs:\n  t:\n    runs-on: x\n    steps:\n      - run: echo ${{ secrets[matrix.name] }}\n"
        self.assertIn("read dynamically", security.check(repository({"x.yml": dynamic}))[0])
        inline = "name: x\non: [push, pull_request_target]\njobs:\n  t:\n    runs-on: x\n    steps:\n      - run: echo\n"
        self.assertIn("must be a block", security.check(repository({"x.yml": inline}))[0])

    def test_the_documented_inherit_exception_is_only_swift_store_assets(self):
        text = "name: x\non:\n  push:\njobs:\n  store-assets:\n    uses: ./.github/workflows/y.yml\n    secrets: inherit\n"
        self.assertEqual(security.check(repository({"swift.yml": text})), [])
        self.assertEqual(len(security.check(repository({"other.yml": text}))), 1)

    def test_a_composite_action_cannot_read_a_paid_secret(self):
        action = "name: a\nruns:\n  using: composite\n  steps:\n    - run: echo ${{ secrets.OPENAI_API_KEY }}\n"
        findings = security.check(repository({}, actions={"a": action}))
        self.assertIn("takes secrets as inputs", findings[0])

    def test_codeowners_must_exist_and_cover_the_workflows(self):
        self.assertIn("missing", security.check(repository({}, codeowners=None))[0])
        self.assertIn("no owner for /.github/", security.check(repository({}, codeowners="/Tools/ @owner\n"))[0])
        self.assertIn("no owner for /.github/", security.check(repository({}, codeowners="/.github/\n"))[0])


if __name__ == "__main__":
    unittest.main()
