import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

import grade


class EvalTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pr-graph-eval-")
        self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name)
        self.fixture = self.run / "fixture"
        (self.run / "outputs").mkdir()
        self.env = {**os.environ, "PR_GRAPH_EVAL_VERIFY": ""}

    def command(self, *args, check=True, env=None):
        result = subprocess.run(args, cwd=self.fixture, env=env or self.env,
                                capture_output=True, text=True)
        if check:
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        return result

    def build(self, scenario="new-ticket"):
        result = subprocess.run(["bash", str(Path(grade.EVALS) / "fixtures/build_fixture.sh"),
                                 scenario, str(self.fixture)], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        name = {"new-ticket": "new-ticket-no-ui", "adopt-branch": "adopt-existing-branch",
                "red-edge": "red-verify-routes-to-build",
                "status-constant": "spec-value-no-tautologies",
                "dollars-total": "spec-value-no-mocks",
                "temper-requirement": "temper-requirement-and-question",
                "temper-decision": "temper-decision-asks"}[scenario]
        self.name = name
        self.branch, self.ticket = grade.CFG[name]
        if scenario != "adopt-branch":
            self.command("git", "checkout", "-qb", self.branch)

    def commit(self):
        self.command("git", "add", "-A")
        self.command("git", "commit", "-qm", "Commit candidate")

    def csv_implementation(self, header="total"):
        path = self.fixture / "lib/acme/vendor_list.rb"
        path.write_text(path.read_text() + '''
require "csv"
class Acme::VendorList
  def to_csv
    CSV.generate do |csv|
      csv << ["name", "city", "HEADER"]
      sorted_by_name.each { |v| csv << [v.name, v.city, format("%.2f", v.total_cents / 100.0)] }
    end
  end
end
'''.replace("HEADER", header))

    def feature_test(self, method="to_csv"):
        (self.fixture / "test/feature_test.rb").write_text('''
require "minitest/autorun"
require_relative "../lib/acme/vendor_list"
class FeatureTest < Minitest::Test
  def test_feature
    list = Acme::VendorList.new([])
    ASSERTION
  end
end
'''.replace("ASSERTION", 'assert_equal [], list.in_city("Austin")' if method == "in_city"
           else 'assert_equal "name,city,total\\n", list.to_csv'))

    def candidate(self):
        return grade.candidate_ok(str(self.run), self.branch, self.name)

    def transcript(self, tool=None, **inputs):
        content = [{"type": "tool_use", "name": tool, "input": inputs}] if tool else [
            {"type": "text", "text": "Slim investigation is complete."}]
        (self.run / "outputs/transcript.jsonl").write_text(json.dumps(
            {"type": "assistant", "message": {"content": content}}) + "\n")

    def test_adopt_investigate_attempt_does_not_imply_fanout(self):
        self.build("adopt-branch")
        self.transcript("Agent", name="pg-VERIFY", description="Verify candidate")
        runs = self.run / "state/runs"
        runs.mkdir(parents=True)
        (runs / "adopt.jsonl").write_text(json.dumps(
            {"e": "node", "phase": "start", "node": "INVESTIGATE"}) + "\n")
        results = grade.grade(self.name, str(self.run), self.branch, self.ticket)
        fanout = next(row for row in results if "captured transcript" in row["text"])
        self.assertTrue(fanout["passed"], fanout)

    def test_investigate_agent_is_rejected(self):
        self.transcript("Agent", name="pg-INVESTIGATE-codebase")
        self.assertFalse(grade.no_investigate_fanout(str(self.run))[0])

    def test_investigate_task_description_is_rejected(self):
        self.transcript("Task", description="pg-INVESTIGATE-ticket fetch context")
        self.assertFalse(grade.no_investigate_fanout(str(self.run))[0])

    def test_parent_text_is_not_mistaken_for_a_spawn(self):
        self.transcript()
        self.assertTrue(grade.no_investigate_fanout(str(self.run))[0])

    def test_missing_transcript_fails_closed(self):
        self.assertFalse(grade.no_investigate_fanout(str(self.run))[0])

    def test_malformed_transcript_fails_closed(self):
        (self.run / "outputs/transcript.jsonl").write_text("not json\n")
        self.assertFalse(grade.no_investigate_fanout(str(self.run))[0])

    def test_malformed_transcript_shapes_fail_closed(self):
        for record in [[], {"type": "assistant", "message": "invalid"},
                       {"type": "assistant", "message": {"content": [
                           {"type": "tool_use", "name": "Agent", "input": "invalid"}]}}]:
            with self.subTest(record=record):
                (self.run / "outputs/transcript.jsonl").write_text(json.dumps(record) + "\n")
                self.assertFalse(grade.no_investigate_fanout(str(self.run))[0])

    def test_empty_transcript_fails_closed(self):
        (self.run / "outputs/transcript.jsonl").write_text("")
        self.assertFalse(grade.no_investigate_fanout(str(self.run))[0])

    def test_red_injection_survives_preliminary_and_build_tests(self):
        self.build("red-edge")
        marker = self.fixture / ".inject_one_failure"
        for _ in range(2):
            self.command("bash", "bin/test")
            self.assertTrue(marker.exists())
        verify_env = {**self.env, "PR_GRAPH_EVAL_VERIFY": "1"}
        first = self.command("bash", "bin/test", env=verify_env, check=False)
        self.assertEqual(1, first.returncode)
        self.assertIn("VendorListTest#test_export_header", first.stdout)
        self.assertFalse(marker.exists())
        self.command("bash", "bin/test", env=verify_env)

    def test_verify_does_not_inject_in_other_scenarios(self):
        self.build()
        self.command("bash", "bin/test", env={**self.env, "PR_GRAPH_EVAL_VERIFY": "1"})

    def test_unrelated_commit_cannot_satisfy_feature(self):
        self.build()
        self.commit()
        self.assertFalse(self.candidate()[0])

    def test_dirty_implementation_and_tests_do_not_satisfy_feature(self):
        self.build()
        self.commit()
        self.csv_implementation()
        self.feature_test()
        self.command("bash", "bin/test")
        self.assertFalse(self.candidate()[0])

    def test_staged_implementation_and_tests_do_not_satisfy_feature(self):
        self.build()
        self.commit()
        self.csv_implementation()
        self.feature_test()
        self.command("git", "add", "-A")
        status = self.command("git", "status", "--porcelain").stdout
        self.assertFalse(self.candidate()[0])
        self.assertEqual(status, self.command("git", "status", "--porcelain").stdout)

    def test_committed_csv_solution_passes(self):
        self.build()
        self.csv_implementation()
        self.feature_test()
        self.commit()
        ok, evidence = self.candidate()
        self.assertTrue(ok, evidence)

    def test_dirty_test_cannot_cover_committed_implementation(self):
        self.build()
        self.csv_implementation()
        self.commit()
        self.feature_test()
        ok, evidence = self.candidate()
        self.assertFalse(ok)
        self.assertIn("committed_test=False", evidence)

    def test_contract_rejects_wrong_csv_even_when_suite_is_green(self):
        self.build()
        self.csv_implementation(header="total_cents")
        self.commit()
        self.command("bash", "bin/test")
        ok, evidence = self.candidate()
        self.assertFalse(ok)
        self.assertIn("command=ruby rc=1", evidence)

    def test_contract_rejects_csv_ordering_and_amount_errors(self):
        self.build()
        self.csv_implementation()
        path = self.fixture / "lib/acme/vendor_list.rb"
        good = path.read_text()
        for before, after in [("sorted_by_name.each", "@vendors.each"),
                              ('format("%.2f", v.total_cents / 100.0)', "v.total_cents.to_s")]:
            with self.subTest(defect=after):
                path.write_text(good.replace(before, after))
                self.commit()
                self.command("bash", "bin/test")
                ok, evidence = self.candidate()
                self.assertFalse(ok)
                self.assertIn("command=ruby rc=1", evidence)

    def test_committed_red_suite_is_not_hidden_by_dirty_fix(self):
        self.build()
        self.csv_implementation()
        self.feature_test()
        path = self.fixture / "test/feature_test.rb"
        good = path.read_text()
        path.write_text(good.replace("name,city,total", "wrong"))
        self.commit()
        path.write_text(good)
        self.command("bash", "bin/test")
        ok, evidence = self.candidate()
        self.assertFalse(ok)
        self.assertIn("command=bash rc=1", evidence)

    def test_adopt_requires_committed_city_test(self):
        self.build("adopt-branch")
        self.feature_test("in_city")
        self.command("bash", "bin/test")
        self.assertFalse(self.candidate()[0])
        self.commit()
        ok, evidence = self.candidate()
        self.assertTrue(ok, evidence)

    def test_comment_only_feature_reference_is_not_test_evidence(self):
        self.build("adopt-branch")
        (self.fixture / "test/city_test.rb").write_text("# TODO: add an in_city test\n")
        self.commit()
        self.command("bash", "bin/test")
        self.assertFalse(self.candidate()[0])

    def test_nested_feature_test_not_run_by_suite_is_not_evidence(self):
        self.build("adopt-branch")
        nested = self.fixture / "test/nested"
        nested.mkdir()
        (nested / "city_test.rb").write_text('raise "in_city test must run"\n')
        self.commit()
        self.command("bash", "bin/test")
        self.assertFalse(self.candidate()[0])

    def test_unexecuted_or_assertionless_feature_test_is_not_evidence(self):
        self.build("adopt-branch")
        self.feature_test("in_city")
        path = self.fixture / "test/feature_test.rb"
        good = path.read_text()
        assertion = 'assert_equal [], list.in_city("Austin")'
        for test in [good.replace("test_feature", "unused_helper"),
                     good.replace("list =", 'skip "not implemented"\n    list ='),
                     good.replace(assertion, assertion + '\n    skip "not implemented"'),
                     good.replace(assertion, 'list.in_city("Austin")'),
                     good.replace(assertion, "assert true") + '\nAcme::VendorList.new([]).in_city("Austin")\n']:
            with self.subTest(test=test):
                path.write_text(test)
                self.commit()
                self.command("bash", "bin/test")
                self.assertFalse(self.candidate()[0])

    def test_feature_evidence_follows_the_committed_suite_runner(self):
        self.build("adopt-branch")
        self.feature_test("in_city")
        runner = self.fixture / "bin/test"
        original = runner.read_text()
        runner.write_text(original.replace("test/*_test.rb", "test/vendor_list_test.rb"))
        self.commit()
        self.assertFalse(self.candidate()[0])
        nested = self.fixture / "test/nested"
        nested.mkdir()
        feature = self.fixture / "test/feature_test.rb"
        (nested / "city_test.rb").write_text(feature.read_text().replace("../lib/", "../../lib/"))
        feature.unlink()
        runner.write_text(original.replace("test/*_test.rb", "test/*_test.rb test/nested/*_test.rb"))
        self.commit()
        ok, evidence = self.candidate()
        self.assertTrue(ok, evidence)

    def test_candidate_run_path_is_literal(self):
        self.run = self.run / "run [square brackets]"
        self.run.mkdir()
        self.fixture = self.run / "fixture"
        self.build("adopt-branch")
        self.feature_test("in_city")
        self.commit()
        ok, evidence = self.candidate()
        self.assertTrue(ok, evidence)

    def prepare_adopt(self):
        self.build("adopt-branch")
        self.feature_test("in_city")
        self.commit()
        self.transcript()
        (self.run / "outputs/pr_description.md").write_text(
            "Add in_city filtering for exact vendor city matches. ACME-102\n")
        (self.run / "outputs/final_report.md").write_text("VERIFY wall time and token usage\nTemper skipped: the ticket has no Linear project\n")

    def adopt_logs(self, nodes=None, omit=(), candidate=None, passing=True, standalone_review=False):
        families = {"TRIAGE": ["triage_brief"], "INVESTIGATE": ["investigation_report"],
                    "PLAN": ["implementation_plan", "test_plan"], "WORKTREE": ["worktree_manifest"],
                    "REPRODUCE": ["repro_report"],
                    "BUILD": ["build_manifest", "self_review"], "VERIFY": ["verification"],
                    "SELF-REVIEW": ["self_review"], "PUBLISH": ["publish_manifest"]}
        if standalone_review:
            families["BUILD"] = ["build_manifest"]
            nodes = [*grade.WORKFLOW_NODES[:-1], "SELF-REVIEW", "PUBLISH"]
        runs = self.run / "state/runs"
        runs.mkdir(parents=True, exist_ok=True)
        blobs = runs / "adopt.artifacts"
        blobs.mkdir(exist_ok=True)
        self.events_path = runs / "adopt.jsonl"
        self.artifacts_path = runs / "adopt.artifacts.jsonl"
        run_id, session = str(uuid.uuid4()), str(uuid.uuid4())
        sha = candidate or self.command("git", "rev-parse", "HEAD").stdout.strip()
        events, artifacts = [], []

        def append(stream, payload):
            stream.append({"v": 1, "run_id": run_id, "session": session,
                           "seq": len(stream) + 1, "ts": "2026-09-16T00:00:00Z", **payload})

        append(events, {"e": "run_start", "ticket": self.ticket, "entry": "adopt"})
        for node in nodes or grade.WORKFLOW_NODES:
            attempt = str(uuid.uuid4())
            event = {"e": "node", "node": node, "attempt_id": attempt, "iteration": 1}
            append(events, {**event, "phase": "start"})
            for family in families[node]:
                if family in omit:
                    continue
                artifact_id = str(uuid.uuid4())
                content = json.dumps({"evidence": f"{node} fixture evidence"}).encode()
                blob = blobs / f"{artifact_id}.blob"
                blob.write_bytes(content)
                append(artifacts, {"e": "artifact", "artifact_id": artifact_id, "family": family,
                                   "node": node, "attempt_id": attempt, "producer": "eval-test",
                                   "input_sha": sha, "candidate_sha": sha,
                                   "content_type": "application/json", "content_ref": f"adopt.artifacts/{blob.name}",
                                   "content_bytes": len(content), "content_sha256": hashlib.sha256(content).hexdigest(),
                                   "wake_id": None, "perspective": "automated_check",
                                   "covered_outcomes": ["outcome:city-filter"]})
            if node in ("VERIFY", "SELF-REVIEW") and passing is not None:
                append(events, {"e": "outcome", "kind": "verify" if node == "VERIFY" else "self_review",
                                "attempt_id": attempt, "pass": passing, "n": 0 if passing else 1})
            append(events, {**event, "phase": "done"})
        self.events_path.write_text("".join(json.dumps(row) + "\n" for row in events))
        self.artifacts_path.write_text("".join(json.dumps(row) + "\n" for row in artifacts))

    def adopt_results(self):
        return grade.grade(self.name, str(self.run), self.branch, self.ticket)

    def test_adopt_verify_and_review_only_cannot_get_full_credit(self):
        self.prepare_adopt()
        self.adopt_logs(nodes=["VERIFY", "SELF-REVIEW"], omit=["verification", "self_review"], passing=None)
        results = self.adopt_results()
        self.assertTrue(results[0]["passed"], results[0])
        self.assertFalse(all(row["passed"] for row in results), results)

    def test_adopt_complete_workflow_and_artifacts_pass(self):
        self.prepare_adopt()
        self.adopt_logs()
        self.assertNotIn("SELF-REVIEW", [row.get("node") for row in grade.rows(self.events_path)])
        review = next(row for row in grade.rows(self.artifacts_path) if row["family"] == "self_review")
        self.assertEqual("BUILD", review["node"])
        results = self.adopt_results()
        self.assertTrue(all(row["passed"] for row in results), results)

    def test_standalone_review_cannot_replace_build_review(self):
        self.prepare_adopt()
        self.adopt_logs(standalone_review=True)
        results = self.adopt_results()
        self.assertTrue(results[0]["passed"], results[0])
        self.assertTrue(results[1]["passed"], results[1])
        self.assertFalse(all(row["passed"] for row in results), results)

    def test_each_scenario_checks_current_build_review_evidence(self):
        self.prepare_adopt()
        # The decision scenario stops at a question, so it has no completed workflow to check.
        for scenario in [name for name in grade.CFG if name != "temper-decision-asks"]:
            for omit in [(), ("self_review",)]:
                with self.subTest(scenario=scenario, omit=omit):
                    self.adopt_logs(omit=omit)
                    results = grade.grade(scenario, str(self.run), self.branch, self.ticket)
                    evidence = next(row for row in results if row["text"].startswith("Completed workflow nodes"))
                    self.assertEqual(not omit, evidence["passed"], evidence)

    def rewrite_events(self, events):
        self.events_path.write_text("".join(json.dumps({**row, "seq": index}) + "\n"
                                           for index, row in enumerate(events, start=1)))

    def test_adopt_rejects_reversed_dependency_order(self):
        self.prepare_adopt()
        self.adopt_logs(nodes=list(reversed(grade.WORKFLOW_NODES)))
        results = self.adopt_results()
        self.assertTrue(results[0]["passed"], results[0])
        self.assertTrue(results[1]["passed"], results[1])
        self.assertFalse(all(row["passed"] for row in results), results)

    def test_adopt_requires_dependencies_to_finish_before_start(self):
        self.prepare_adopt()
        for parent, child in [("TRIAGE", "INVESTIGATE"), ("TRIAGE", "WORKTREE"),
                              ("INVESTIGATE", "PLAN"), ("INVESTIGATE", "REPRODUCE"), ("WORKTREE", "REPRODUCE"),
                              ("REPRODUCE", "PLAN"), ("PLAN", "BUILD"), ("WORKTREE", "BUILD"),
                              ("BUILD", "VERIFY"), ("VERIFY", "PUBLISH")]:
            with self.subTest(parent=parent, child=child):
                self.adopt_logs()
                events = grade.rows(self.events_path)
                start = next(row for row in events if row.get("node") == child and row.get("phase") == "start")
                events.remove(start)
                finish = next(index for index, row in enumerate(events)
                              if row.get("node") == parent and row.get("phase") == "done")
                events.insert(finish, start)
                self.rewrite_events(events)
                results = self.adopt_results()
                self.assertTrue(results[0]["passed"], results[0])
                self.assertTrue(results[1]["passed"], results[1])
                self.assertFalse(all(row["passed"] for row in results), results)

    def test_adopt_allows_parallel_investigation_and_worktree(self):
        self.prepare_adopt()
        for phase in ["start", "done"]:
            with self.subTest(before_investigate=phase):
                self.adopt_logs()
                events = grade.rows(self.events_path)
                worktree = [row for row in events if row.get("node") == "WORKTREE"]
                events = [row for row in events if row not in worktree]
                position = next(index for index, row in enumerate(events)
                                if row.get("node") == "INVESTIGATE" and row.get("phase") == phase)
                events[position:position] = worktree
                self.rewrite_events(events)
                results = self.adopt_results()
                self.assertTrue(all(row["passed"] for row in results), results)

    def test_adopt_requires_quality_gates_after_latest_build_even_at_same_sha(self):
        self.prepare_adopt()
        for tail, expected in [(["BUILD"], False), (["BUILD", "VERIFY", "PUBLISH"], True)]:
            with self.subTest(tail=tail):
                self.adopt_logs(nodes=list(grade.WORKFLOW_NODES) + tail)
                results = self.adopt_results()
                self.assertTrue(results[0]["passed"], results[0])
                self.assertTrue(results[1]["passed"], results[1])
                self.assertEqual(expected, all(row["passed"] for row in results), results)

    def test_adopt_requires_each_completed_node_artifact(self):
        self.prepare_adopt()
        for family in ["triage_brief", "investigation_report", "implementation_plan", "test_plan",
                       "worktree_manifest", "build_manifest", "verification", "self_review", "publish_manifest"]:
            with self.subTest(family=family):
                self.adopt_logs(omit=[family])
                results = self.adopt_results()
                self.assertFalse(all(row["passed"] for row in results), results)

    def test_adopt_rejects_artifact_from_an_earlier_attempt(self):
        self.prepare_adopt()
        self.adopt_logs()
        events = grade.rows(self.events_path)
        attempt = str(uuid.uuid4())
        for phase in ["start", "done"]:
            events.append({**events[0], "e": "node", "seq": len(events) + 1,
                           "node": "INVESTIGATE", "phase": phase, "attempt_id": attempt, "iteration": 2})
            events[-1].pop("entry")
            events[-1].pop("ticket")
        self.events_path.write_text("".join(json.dumps(row) + "\n" for row in events))
        results = self.adopt_results()
        self.assertTrue(results[1]["passed"], results[1])
        self.assertFalse(all(row["passed"] for row in results), results)

    def test_adopt_rejects_invalidated_artifact(self):
        self.prepare_adopt()
        self.adopt_logs()
        artifacts = grade.rows(self.artifacts_path)
        source = next(row for row in artifacts if row["family"] == "build_manifest")
        target = next(row for row in artifacts if row["family"] == "investigation_report")
        link = {key: source[key] for key in ["v", "run_id", "session", "ts"]}
        link.update(e="link", seq=len(artifacts) + 1, link_id=str(uuid.uuid4()), relation="invalidates",
                    from_artifact_id=source["artifact_id"], to_artifact_id=target["artifact_id"], reason="Reinvestigate")
        with self.artifacts_path.open("a") as stream:
            stream.write(json.dumps(link) + "\n")
        results = self.adopt_results()
        self.assertTrue(results[1]["passed"], results[1])
        self.assertFalse(all(row["passed"] for row in results), results)

    def test_adopt_rejects_corrupt_artifact_content(self):
        self.prepare_adopt()
        self.adopt_logs()
        artifact = grade.rows(self.artifacts_path)[0]
        (self.artifacts_path.parent / artifact["content_ref"]).write_text("corrupt")
        results = self.adopt_results()
        self.assertFalse(all(row["passed"] for row in results), results)

    def test_adopt_rejects_stale_candidate_evidence(self):
        self.prepare_adopt()
        self.adopt_logs(candidate=self.command("git", "rev-parse", "base^{commit}").stdout.strip())
        results = self.adopt_results()
        self.assertFalse(all(row["passed"] for row in results), results)

    def test_adopt_requires_passing_quality_outcomes(self):
        self.prepare_adopt()
        for passing in [False, None]:
            with self.subTest(passing=passing):
                self.adopt_logs(passing=passing)
                results = self.adopt_results()
                self.assertFalse(all(row["passed"] for row in results), results)

    def test_contract_rejects_case_insensitive_city_filter(self):
        self.build("adopt-branch")
        self.feature_test("in_city")
        path = self.fixture / "lib/acme/vendor_list.rb"
        path.write_text(path.read_text().replace("v.city == city", "v.city.downcase == city.downcase"))
        self.commit()
        self.command("bash", "bin/test")
        ok, evidence = self.candidate()
        self.assertFalse(ok)
        self.assertIn("command=ruby rc=1", evidence)

    def test_red_candidate_grading_does_not_consume_injector(self):
        self.build("red-edge")
        self.csv_implementation()
        self.feature_test()
        self.commit()
        ok, evidence = self.candidate()
        self.assertTrue(ok, evidence)
        self.assertTrue((self.fixture / ".inject_one_failure").exists())

    def test_grading_preserves_checkout_and_dirty_files(self):
        self.build()
        self.csv_implementation()
        self.feature_test()
        self.commit()
        self.command("git", "checkout", "-q", "main")
        path = self.fixture / "lib/acme/vendor_list.rb"
        path.write_text(path.read_text() + "# Local scratch\n")
        contents = path.read_bytes()
        status = self.command("git", "status", "--porcelain").stdout
        ok, evidence = self.candidate()
        self.assertTrue(ok, evidence)
        self.assertEqual("main", self.command("git", "branch", "--show-current").stdout.strip())
        self.assertEqual(contents, path.read_bytes())
        self.assertEqual(status, self.command("git", "status", "--porcelain").stdout)
        self.assertEqual([], list(self.run.glob(".grade-*")))

    def test_missing_branch_fails_without_checkout(self):
        self.build()
        self.branch = "missing"
        ok, evidence = self.candidate()
        self.assertFalse(ok)
        self.assertIn("branch missing", evidence)

    def test_cli_grades_all_scenarios_and_variants_with_matching_assertions(self):
        config = json.loads((Path(grade.EVALS) / "evals.json").read_text())
        for scenario in config["evals"]:
            for variant in ("with_skill", "without_skill"):
                run = self.run / scenario["name"] / variant
                (run / "outputs").mkdir(parents=True)
                result = subprocess.run(["bash", str(Path(grade.EVALS) / "fixtures/build_fixture.sh"),
                                         scenario["setup"].split()[1], str(run / "fixture")],
                                        env=self.env, capture_output=True, text=True)
                self.assertEqual(0, result.returncode, result.stderr)
        result = subprocess.run([sys.executable, str(Path(grade.EVALS) / "grade.py"),
                                 str(self.run)], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(2 * len(config["evals"]), len(result.stdout.splitlines()))
        for scenario in config["evals"]:
            for variant in ("with_skill", "without_skill"):
                grading = json.loads((self.run / scenario["name"] / variant / "grading.json").read_text())
                self.assertEqual(scenario["assertions"], [r["text"] for r in grading["expectations"]])
                self.assertEqual(len(scenario["assertions"]), grading["summary"]["total"])
                candidate = next((r for r in grading["expectations"] if r["text"].startswith("The committed")), None)
                if candidate: self.assertFalse(candidate["passed"])

    def status_implementation(self, validate=True, filter_by_status=True):
        (self.fixture / "lib/acme/vendor.rb").write_text('''module Acme
  Vendor = Struct.new(:name, :city, :total_cents, :status, keyword_init: true) do
    def initialize(status: "active", **rest)
      super(status: status, **rest)
    end
  end
  Vendor::STATUSES = %w[active paused closed].freeze
end
''')
        path = self.fixture / "lib/acme/vendor_list.rb"
        path.write_text(path.read_text().replace("    def total_cents", f'''    def with_status(status)
      {"raise ArgumentError, \"unknown status\" unless Vendor::STATUSES.include?(status)" if validate else ""}
      {"@vendors.select { |v| v.status == status }" if filter_by_status else "@vendors"}
    end

    def total_cents'''))

    BEHAVIOR_TESTS = '''
  def vendors
    %w[active paused closed active].each_with_index.map do |status, i|
      Acme::Vendor.new(name: "V#{i}", city: "Austin", total_cents: i, status: status)
    end
  end

  def test_with_status_filters
    assert_equal [vendors[1]], Acme::VendorList.new(vendors).with_status("paused")
    assert_equal [vendors[0], vendors[3]], Acme::VendorList.new(vendors).with_status("active")
  end

  def test_with_status_rejects_unknown
    assert_raises(ArgumentError) { Acme::VendorList.new(vendors).with_status("archived") }
  end
'''

    def status_tests(self, body=BEHAVIOR_TESTS):
        (self.fixture / "test/status_test.rb").write_text(f'''require "minitest/autorun"
require_relative "../lib/acme/vendor_list"
class StatusTest < Minitest::Test
{body}end
''')

    TAUTOLOGIES = '''
  def test_statuses_are_frozen
    assert_predicate Acme::Vendor::STATUSES, :frozen?
  end

  def test_status_count
    assert_equal 3, Acme::Vendor::STATUSES.size
  end

  def test_status_members
    assert_equal %w[active paused closed], Acme::Vendor::STATUSES
  end
'''

    def spec_value(self, tests=BEHAVIOR_TESTS, **implementation):
        self.build("status-constant")
        self.status_implementation(**implementation)
        self.status_tests(tests)
        self.commit()
        return grade.tautological_specs(str(self.run), self.branch), grade.mutants_killed(str(self.run), self.branch)

    def test_behavior_specs_pass_spec_value_checks(self):
        tautology, mutants = self.spec_value()
        self.assertTrue(tautology[0], tautology)
        self.assertTrue(mutants[0], mutants)

    def test_constant_restating_specs_are_flagged_even_with_behavior_specs(self):
        tautology, _ = self.spec_value(self.BEHAVIOR_TESTS + self.TAUTOLOGIES)
        self.assertFalse(tautology[0])
        for line in ["assert_predicate", ".size", "assert_equal %w[active"]:
            self.assertIn(line, tautology[1])

    def test_constant_only_suite_survives_every_mutant(self):
        tautology, mutants = self.spec_value(self.TAUTOLOGIES)
        self.assertFalse(tautology[0])
        self.assertFalse(mutants[0])
        for mutant in grade.MUTANTS:
            self.assertIn(mutant, mutants[1])

    def test_each_mutant_needs_its_own_spec(self):
        weak = {"returns-none": '''
  def vendors
    [Acme::Vendor.new(name: "A", city: "Austin", total_cents: 1, status: "paused")]
  end

  def test_unknown_status_rejected
    assert_raises(ArgumentError) { Acme::VendorList.new(vendors).with_status("archived") }
  end
'''}
        _, mutants = self.spec_value(weak["returns-none"])
        self.assertFalse(mutants[0])
        self.assertIn("survivors=['returns-none']", mutants[1])

    def test_mutant_is_reported_unapplied_without_with_status(self):
        self.build("status-constant")
        self.feature_test()
        self.commit()
        ok, evidence = grade.mutants_killed(str(self.run), self.branch)
        self.assertFalse(ok)
        self.assertIn("unapplied", evidence)

    def test_status_contract_rejects_missing_validation(self):
        self.build("status-constant")
        self.status_implementation(validate=False)
        self.status_tests(self.BEHAVIOR_TESTS.split("  def test_with_status_rejects_unknown")[0])
        self.commit()
        ok, evidence = self.candidate()
        self.assertFalse(ok)
        self.assertIn("command=ruby rc=1", evidence)

    def dollars(self, body):
        shutil.rmtree(self.fixture, ignore_errors=True)
        self.build("dollars-total")
        path = self.fixture / "lib/acme/vendor_list.rb"
        path.write_text(path.read_text().replace("    def total_cents", '''    def total_dollars
      format("%.2f", total_cents / 100.0)
    end

    def total_cents'''))
        self.status_tests(body)
        self.commit()
        return (grade.tautological_specs(str(self.run), self.branch, self.name),
                grade.mutants_killed(str(self.run), self.branch, self.name))

    DOLLAR_TESTS = '''
  def list(*cents)
    Acme::VendorList.new(cents.map { |c| Acme::Vendor.new(name: "V", city: "Austin", total_cents: c) })
  end

  def test_total_dollars
    assert_equal "170.49", list(12_050, 4_999).total_dollars
    assert_equal "120.50", list(12_050).total_dollars
    assert_equal "0.00", list.total_dollars
  end
'''

    def test_literal_dollar_specs_pass_spec_value_checks(self):
        scan, mutants = self.dollars(self.DOLLAR_TESTS)
        self.assertTrue(scan[0], scan)
        self.assertTrue(mutants[0], mutants)

    def test_mock_type_and_recomputed_specs_are_flagged(self):
        for line in ['assert_kind_of String, list(1).total_dollars',
                     'assert_equal format("%.2f", list(12_050).total_cents / 100.0), list(12_050).total_dollars',
                     'l = list(1); l.stub(:total_cents, 5) { assert_equal "0.05", l.total_dollars }']:
            with self.subTest(line=line):
                scan, _ = self.dollars(self.DOLLAR_TESTS.replace("  def test_total_dollars", f"  def test_extra\n    {line}\n  end\n\n  def test_total_dollars"))
                self.assertFalse(scan[0])

    def test_lines_already_in_the_fixture_are_not_the_candidates_specs(self):
        self.dollars(self.DOLLAR_TESTS)
        existing = self.fixture / "test/vendor_list_test.rb"
        self.assertIn("@list.total_cents", existing.read_text())
        existing.write_text(existing.read_text().rstrip().removesuffix("end") +
                            '  def test_total_dollars\n    assert_equal "170.49", @list.total_dollars\n  end\nend\n')
        self.commit()
        scan = grade.tautological_specs(str(self.run), self.branch, self.name)
        self.assertTrue(scan[0], scan)
        existing.write_text(existing.read_text().rstrip().removesuffix("end") +
                            '  def test_recomputed\n    assert_equal format("%.2f", @list.total_cents / 100.0), @list.total_dollars\n  end\nend\n')
        self.commit()
        scan = grade.tautological_specs(str(self.run), self.branch, self.name)
        self.assertFalse(scan[0])
        self.assertIn("test/vendor_list_test.rb:", scan[1])

    def test_missing_trailing_zero_case_survives_no_padding(self):
        _, mutants = self.dollars(self.DOLLAR_TESTS.replace('    assert_equal "120.50", list(12_050).total_dollars\n', "")
                                  .replace('    assert_equal "0.00", list.total_dollars\n', ""))
        self.assertFalse(mutants[0])
        self.assertIn("survivors=['no-padding']", mutants[1])

    def artifacts(self, family, docs):
        runs = self.run / "state/runs"
        (runs / "x.artifacts").mkdir(parents=True, exist_ok=True)
        art = runs / "x.artifacts.jsonl"
        with art.open("a") as stream:
            for i, doc in enumerate(docs):
                blob = runs / "x.artifacts" / f"{family}-{i}.blob"
                blob.write_text(json.dumps(doc))
                stream.write(json.dumps({"e": "artifact", "family": family, "content_ref": f"x.artifacts/{blob.name}"}) + "\n")
        return str(art)

    def test_spec_first_requires_well_formed_red_runs(self):
        for doc, expected in [({"spec_first": [{"ref": "test/a_test.rb:3", "excerpt": "Expected \"0.00\", got nil"}]}, True),
                              ({"spec_first": []}, False), ({}, False),
                              ({"spec_first": [{"ref": "test/a_test.rb", "excerpt": "x"}]}, False),
                              ({"spec_first": True}, False), ({"spec_first": ["test/a_test.rb:3"]}, False)]:
            with self.subTest(doc=doc):
                for blob in (self.run / "state").rglob("*"):
                    if blob.is_file(): blob.unlink()
                self.assertEqual(expected, grade.spec_first_recorded(self.artifacts("build_manifest", [doc]))[0])

    def test_spec_audit_must_be_clean_for_the_final_candidate(self):
        tip, entry = "a" * 40, {"ref": "test/a_test.rb:3", "classes": [], "mutation": {"change": "x", "result": "fail"}}
        cases = [({"candidate_sha": tip, "specs": [entry]}, True),
                 ({"candidate_sha": "b" * 40, "specs": [entry]}, False),
                 ({"candidate_sha": tip, "specs": []}, False),
                 ({"candidate_sha": tip, "specs": [{**entry, "classes": ["mocks_subject"]}]}, False),
                 ({"candidate_sha": tip, "specs": [{**entry, "mutation": {"change": "x", "result": "pass"}}]}, False)]
        for audit, expected in cases:
            with self.subTest(audit=audit):
                for blob in (self.run / "state").rglob("*"):
                    if blob.is_file(): blob.unlink()
                self.assertEqual(expected, grade.spec_audit_clean(self.artifacts("verification", [{"spec_audit": audit}]), tip)[0])

    def temper(self, *args):
        return subprocess.run([str(self.fixture / ".harness/temper"), *args], capture_output=True, text=True)

    def test_temper_harness_serves_only_the_scenario_context(self):
        self.build("temper-requirement")
        listed = self.temper("resource", "list", "--context", grade.TEMPER_CONTEXT, "--all", "--with", "open-meta", "--format", "json")
        self.assertEqual(0, listed.returncode, listed.stderr)
        self.assertIn(grade.TEMPER_REQUIREMENT, listed.stdout)
        self.assertEqual("", self.command("git", "status", "--short", "--", ".harness").stdout)
        other = self.run / "off"
        subprocess.run(["bash", str(Path(grade.EVALS) / "fixtures/build_fixture.sh"), "new-ticket", str(other)],
                       env=self.env, capture_output=True, text=True, check=True)
        refused = subprocess.run([str(other / ".harness/temper"), "resource", "list", "--context", grade.TEMPER_CONTEXT],
                                 capture_output=True, text=True)
        self.assertEqual(1, refused.returncode)
        self.assertIn("forbidden", refused.stdout)

    def test_temper_off_needs_a_skip_and_no_resource_call(self):
        self.build()
        self.assertEqual((False, "resource_calls=[] skipped=False"), grade.temper_skipped(str(self.run), "", ""))
        self.assertTrue(grade.temper_skipped(str(self.run), "", "Temper skipped: the ticket has no Linear project")[0])
        self.temper("search", "vendor csv")
        self.assertTrue(grade.temper_skipped(str(self.run), "", "Temper skipped: the ticket has no Linear project")[0])
        self.temper("resource", "list", "--context", grade.TEMPER_CONTEXT)
        self.assertFalse(grade.temper_skipped(str(self.run), "", "Temper skipped: the ticket has no Linear project")[0])

    def test_temper_read_needs_the_list_and_anchor_and_nothing_else(self):
        self.build("temper-requirement")
        self.assertFalse(grade.temper_read(str(self.run))[0])
        self.temper("resource", "list", "--context", grade.TEMPER_CONTEXT, "--all", "--with", "open-meta", "--format", "json")
        self.assertFalse(grade.temper_read(str(self.run))[0])
        self.temper("resource", "show", grade.TEMPER_ANCHOR, "--format", "json")
        self.assertTrue(grade.temper_read(str(self.run))[0])
        self.temper("resource", "show", grade.TEMPER_REQUIREMENT, "--format", "json")
        self.assertEqual((False, "list=1 show=1 other=1"), grade.temper_read(str(self.run)))

    def test_requirement_must_be_a_register_clause_the_test_plan_covers(self):
        clause = f"requirement:{grade.TEMPER_REQUIREMENT}"
        register = {"positive_postconditions": [{"id": clause, "statement": "x"}], "negative_face": [], "declared_gaps": []}
        gap_only = {"positive_postconditions": [], "negative_face": [], "declared_gaps": [{"id": clause, "reason": "x"}]}
        for brief, plan, expected in [(register, [{"outcome_id": clause}], (True, True)),
                                      (gap_only, [{"outcome_id": clause}], (False, True)),
                                      (register, [{"outcome_id": "positive:export"}], (True, False))]:
            with self.subTest(brief=brief, plan=plan):
                for blob in (self.run / "state").rglob("*"):
                    if blob.is_file(): blob.unlink()
                self.artifacts("triage_brief", [{"outcome_register": brief}])
                art = self.artifacts("test_plan", [{"coverage": plan}])
                self.assertEqual(expected, grade.requirement_coverage(art))

    def test_temper_plan_needs_exactly_one_interpreted_question_and_no_refusals(self):
        question = {"verdict": "new", "doc_type": "question", "textual_or_interpreted": "interpreted",
                    "origin_uri": f"{grade.TEMPER_PR}#pr-graph:triage_brief:gap:credits"}
        decision = {**question, "doc_type": "decision", "origin_uri": f"{grade.TEMPER_PR}#pr-graph:implementation_plan:step:csv"}
        runs = self.run / "state/runs"
        runs.mkdir(parents=True)
        cases = [({"plan": {"resources": [question, decision]}, "refused": []}, True),
                 ({"plan": {"resources": [question, question]}, "refused": []}, False),
                 ({"plan": {"resources": [{**question, "textual_or_interpreted": "textual"}]}, "refused": []}, False),
                 ({"plan": {"resources": [{**question, "origin_uri": "https://example.com/1#pr-graph:x:y"}]}, "refused": []}, False),
                 ({"plan": {"resources": [question]}, "refused": [{"index": 1, "reason": "x"}]}, False),
                 ({"skipped": "the ticket has no Linear project"}, False)]
        self.assertEqual((False, "no temper plan"), grade.temper_question_proposed(str(self.run)))
        for doc, expected in cases:
            with self.subTest(doc=doc):
                (runs / "x.temper-plan.json").write_text(json.dumps(doc))
                self.assertEqual(expected, grade.temper_question_proposed(str(self.run))[0])

    def test_a_committed_json_export_on_any_branch_fails(self):
        self.build("temper-decision")
        self.assertTrue(grade.no_json_export(str(self.run))[0])
        path = self.fixture / "lib/acme/vendor_list.rb"
        path.write_text(path.read_text() + 'require "json"\nclass Acme::VendorList\n  def to_json(*) = "[]"\nend\n')
        self.commit()
        self.command("git", "checkout", "-q", "main")
        self.assertEqual((False, "branches=['acme-107-vendor-json-export', 'main'] json_export=['acme-107-vendor-json-export']"),
                         grade.no_json_export(str(self.run)))

    def test_no_commit_past_base_fails(self):
        self.build()
        ok, evidence = self.candidate()
        self.assertFalse(ok)
        self.assertIn("commits_past_base=0", evidence)


if __name__ == "__main__":
    unittest.main()
