import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/reliability-hardening.yml"


class HardeningWorkflowTests(unittest.TestCase):
    def test_summary_is_written_even_after_an_artifact_download_failure(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("- name: Summarize\n        if: always()\n", workflow)
        step = workflow.split("      - name: Summarize\n", 1)[1].split("      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        script = re.sub(r"\$\{\{.*?\}\}", "example", script)
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            process = subprocess.run(
                ["bash", "-eu", "-c", script],
                env={**os.environ, "RUNNER_TEMP": directory, "GITHUB_STEP_SUMMARY": str(summary)},
                capture_output=True, text=True,
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            output = summary.read_text(encoding="utf-8")
            self.assertIn("## Reliability hardening lane summary", output)
            self.assertEqual(output.count("0/0 passed"), 2)

    def test_summary_job_preserves_every_dependency_result(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        step = workflow.split("      - name: Require successful hardening jobs\n", 1)[1]
        self.assertIn("        if: always()\n", step)
        for variable, job in (
            ("TSAN_RESULT", "thread-sanitizer"),
            ("RELEASE_RESULT", "release-configuration-tests"),
            ("UI_RESULT", "ui-flake-rate"),
        ):
            self.assertIn(f"{variable}: ${{{{ needs.{job}.result }}}}", step)
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        success = dict(TSAN_RESULT="success", RELEASE_RESULT="success", UI_RESULT="success")
        cases = [success]
        for variable in success:
            for result in ("failure", "cancelled", "skipped", ""):
                cases.append({**success, variable: result})
        for results in cases:
            with self.subTest(results=results):
                process = subprocess.run(
                    ["bash", "-eu", "-c", script],
                    env={**os.environ, **results}, capture_output=True, text=True,
                )
                expected = 0 if results == success else 1
                self.assertEqual(process.returncode, expected, process.stderr)
                if expected:
                    self.assertIn("::error::Hardening jobs did not all succeed", process.stdout)


if __name__ == "__main__":
    unittest.main()
