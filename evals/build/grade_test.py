import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import grade


class BuildEvalTest(unittest.TestCase):
    NAME = "build-standalone-no-mocks"
    SPAWNED = "The transcript spawns the pg-BUILD writer and the pg-BUILD-review, pg-BUILD-simplify, and pg-VERIFY-specs lanes"
    PINNED = "Every lane spawn pins its model: pg-BUILD and pg-BUILD-simplify on sonnet, pg-BUILD-review and pg-VERIFY-specs on opus"
    TESTS = '''require "minitest/autorun"
require_relative "../lib/acme/vendor_list"
class DollarsTest < Minitest::Test
  def list(*cents)
    Acme::VendorList.new(cents.map { |c| Acme::Vendor.new(name: "V", city: "Austin", total_cents: c) })
  end

  def test_total_dollars
    assert_equal "170.49", list(12_050, 4_999).total_dollars
    assert_equal "120.50", list(12_050).total_dollars
    assert_equal "0.00", list.total_dollars
  end
end
'''

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="build-eval-")
        self.addCleanup(temp.cleanup)
        self.run_dir = Path(temp.name)
        self.fixture = self.run_dir / "fixture"
        (self.run_dir / "outputs").mkdir()
        self.branch = grade.CFG[self.NAME][1]
        subprocess.run(["bash", str(Path(grade.PR_GRAPH) / "evals/fixtures/build_fixture.sh"), "dollars-total",
                        str(self.fixture)], check=True, capture_output=True)
        self.git("checkout", "-qb", self.branch)
        path = self.fixture / "lib/acme/vendor_list.rb"
        path.write_text(path.read_text().replace("    def total_cents", '''    def total_dollars
      format("%.2f", total_cents / 100.0)
    end

    def total_cents'''))
        (self.fixture / "test/dollars_test.rb").write_text(self.TESTS)
        self.git("add", "-A")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "Add total_dollars")
        self.tip = self.git("rev-parse", "HEAD")
        self.base = self.git("rev-parse", "base^{commit}")
        self.report = {
            "base_sha": self.base, "candidate_sha": self.tip, "no_spec_reason": None, "review": [],
            "spec_first": [{"ref": "test/dollars_test.rb:9", "excerpt": "NoMethodError: undefined method `total_dollars'"}],
            "spec_audit": {"candidate_sha": self.tip, "base_sha": self.base, "specs": [
                {"ref": "test/dollars_test.rb:8", "behavior": "cents render as a two-place dollar string", "classes": [],
                 "mutation": {"change": "drop the zero padding", "result": "fail"}}]},
        }
        self.lanes(*grade.LANES.items())

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.fixture), *args], check=True, capture_output=True,
                              text=True).stdout.strip()

    def lanes(self, *spawns):
        rows = [{"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Agent", "input": {"description": d, "model": m, "prompt": "x"}}
            for d, m in spawns]}}]
        (self.run_dir / "outputs/transcript.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")

    def results(self):
        (self.run_dir / "outputs/build_report.json").write_text(json.dumps(self.report))
        return {r["text"]: r for r in grade.grade(self.NAME, str(self.run_dir))}

    def failed(self):
        return [text for text, r in self.results().items() if not r["passed"]]

    def test_a_standalone_build_with_a_clean_report_passes_every_assertion(self):
        self.assertEqual([], self.failed())

    def test_spec_first_must_cite_every_changed_test_file(self):
        self.report["spec_first"] = [{"ref": "test/other_test.rb:3", "excerpt": "red"}]
        self.assertEqual(["build_report.json records a well-formed red spec_first run citing every changed test file"],
                         self.failed())

    def test_spec_audit_is_checked_by_the_real_contract(self):
        audit = self.report["spec_audit"]
        for change, needle in [({"base_sha": self.tip}, "must diff against the run's base"),
                               ({"specs": [{**audit["specs"][0], "classes": ["mocks_subject"]}]}, "(mocks_subject)"),
                               ({"specs": [{**audit["specs"][0], "ref": "test/other_test.rb:1"}]}, "did not add or change")]:
            with self.subTest(change=change):
                self.report["spec_audit"] = {**audit, **change}
                result = self.results()["build_report.json carries a spec_audit of the final candidate against the base that spec_audit.rb check accepts"]
                self.assertFalse(result["passed"])
                self.assertIn(needle, result["evidence"])

    def test_every_lane_must_be_spawned(self):
        self.lanes(("pg-BUILD-review", "opus"), ("pg-BUILD-simplify", "sonnet"))
        result = self.results()[self.SPAWNED]
        self.assertFalse(result["passed"])
        self.assertEqual("spawns=2 missing=['pg-BUILD', 'pg-VERIFY-specs']", result["evidence"])

    def test_a_lane_on_the_wrong_model_or_unpinned_fails_the_pin_assertion(self):
        self.lanes(("pg-BUILD writer", "opus"), ("pg-BUILD-review", "opus"), ("pg-BUILD-simplify", ""),
                   ("pg-VERIFY-specs", "opus"))
        self.assertEqual([self.PINNED], self.failed())
        self.assertIn("wrong=['pg-BUILD=opus', 'pg-BUILD-simplify=unpinned']", self.results()[self.PINNED]["evidence"])

    def test_a_graph_run_fails_the_standalone_assertion(self):
        (self.run_dir / "state/runs").mkdir(parents=True)
        (self.run_dir / "state/runs/x.jsonl").write_text("{}\n")
        self.assertEqual(["No pr-graph run was started (no execution, artifact, or failure stream)"], self.failed())

    def test_evals_json_assertions_match_the_grader(self):
        evals = json.loads((Path(grade.EVALS) / "evals.json").read_text())["evals"]
        self.assertEqual(sorted(grade.CFG), sorted(e["name"] for e in evals))
        for e in evals:
            with tempfile.TemporaryDirectory() as empty:
                os.mkdir(os.path.join(empty, "fixture"))
                self.assertEqual([r["text"] for r in grade.grade(e["name"], empty)], e["assertions"])


if __name__ == "__main__":
    unittest.main()
