# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/giraffe/node_view"

# One node's part of a run's graph view, built from the node's own rules and dependencies and from what the run
# has done. It needs no run, coordinator or store; GraphViewTest pins it again through the whole view.
class NodeViewTest < Minitest::Test
  Progress = Giraffe::NodeView::Progress

  # A state with no `manifests` key at all is `manifests: nil`.
  def progress(run_status: "running", questions: [], attempts: [], artifacts: [], manifests: {}, runnable: [], blocked: {})
    state = {"attempts" => attempts.to_h { |row| [row["attempt_id"], row] }, "artifacts" => artifacts, "manifests" => manifests}.compact
    Progress.new(run_status: run_status, questions: questions, state: state, projection: {"runnable" => runnable, "blocked" => blocked})
  end

  def view(name = "BUILD", rules: {}, dependencies: [], **given) = Giraffe::NodeView.new(name, rules, dependencies, progress(**given))
  def status(...) = view(...).to_h["status"]

  def attempt(node, id, start_seq, state: "open", **more)
    {"attempt_id" => id, "node" => node, "iteration" => 1, "label" => "pg-#{node}", "state" => state, "start_seq" => start_seq}.merge(more.transform_keys(&:to_s))
  end

  def closed(node, id, start_seq, **more) = attempt(node, id, start_seq, state: "closed", done_seq: start_seq + 1, **more)
  def result(state) = {"lease" => {}, "result" => {"state" => state}}

  def artifact(node, id, **more)
    {"family" => "verification", "node" => node, "attempt_id" => "a-#{node}", "producer" => "giraffe-harness", "input_sha" => "0" * 40, "candidate_sha" => nil,
     "content_type" => "application/json", "wake_id" => nil, "perspective" => "author", "covered_outcomes" => [], "e" => "artifact", "artifact_id" => id,
     "content_ref" => "run.artifacts/#{id}.blob", "content_sha256" => "f" * 64, "content_bytes" => 12, "v" => 1, "seq" => 1, "status" => "current"}.merge(more.transform_keys(&:to_s))
  end

  def deep_freeze(value)
    case value
    when Array then value.each { |held| deep_freeze(held) }
    when Hash then value.each { |key, held| [key, held].each { |part| deep_freeze(part) } }
    end
    value.freeze
  end

  def test_progress_is_the_runs_status_and_questions_and_the_coordinators_state_and_projection
    assert_equal %i[run_status questions state projection], Progress.members
    assert_predicate progress, :frozen?
    assert_equal progress, progress
  end

  def test_a_node_with_no_attempt_is_runnable_retired_or_blocked
    assert_equal "blocked", status
    assert_equal "runnable", status(runnable: ["BUILD"])
    assert_equal "runnable", status(runnable: %w[PLAN BUILD])
    assert_equal "blocked", status(runnable: ["PLAN"])
    assert_equal "retired", status(rules: {"retired" => true})
    assert_equal "runnable", status(rules: {"retired" => true}, runnable: ["BUILD"])
  end

  def test_an_open_attempt_is_active_unless_the_run_is_stopped_or_a_question_is_asked_of_it
    open = attempt("BUILD", "a1", 4)
    assert_equal "active", status(attempts: [open], runnable: ["BUILD"])
    assert_equal %w[paused cancelled], %w[paused cancelled].map { |stopped| status(attempts: [open], run_status: stopped) }
    assert_equal "active", status(attempts: [open], run_status: "waiting_for_answers")
    assert_equal "waiting_for_answers", status(attempts: [open], questions: [{"attempt_id" => "a1"}])
    assert_equal "active", status(attempts: [open], questions: [{"attempt_id" => "elsewhere"}])
    assert_equal "paused", status(attempts: [open], questions: [{"attempt_id" => "a1"}], run_status: "paused")
    assert_equal "blocked", status(run_status: "paused"), "a node without an open attempt does not take the run's status"
  end

  def test_a_closed_attempt_leaves_the_node_completed_or_failed_unless_the_node_can_run_again
    attempts = [closed("BUILD", "a1", 4)]
    assert_equal "completed", status(attempts: attempts)
    assert_equal "completed", status(attempts: attempts, manifests: {"a1" => result("completed")})
    assert_equal "completed", status(attempts: attempts, manifests: {"a1" => {"lease" => {}, "result" => nil}})
    assert_equal "completed", status(attempts: attempts, manifests: nil)
    assert_equal %w[failed failed], %w[failed mutation_violation].map { |state| status(attempts: attempts, manifests: {"a1" => result(state)}) }
    assert_equal "runnable", status(attempts: attempts, runnable: ["BUILD"], manifests: {"a1" => result("failed")})
    assert_equal "completed", status(rules: {"retired" => true}, attempts: attempts)
  end

  def test_the_newest_attempt_by_start_seq_decides_whatever_order_they_come_in
    older, newer = closed("BUILD", "a1", 4), closed("BUILD", "a2", 6)
    manifests = {"a1" => result("failed"), "a2" => result("completed")}
    assert_equal %w[completed completed], [[older, newer], [newer, older]].map { |attempts| status(attempts: attempts, manifests: manifests) }
    assert_equal "active", status(attempts: [attempt("BUILD", "a3", 8), newer, older])
  end

  def test_it_is_the_nodes_id_status_dependencies_attempts_blocked_reasons_and_artifacts_in_that_order
    attempts = [attempt("VERIFY", "a2", 6, iteration: 2, lease_id: "l2"), closed("VERIFY", "a1", 4, lease_id: "l1"), closed("BUILD", "b1", 2)]
    artifacts = [artifact("BUILD", "x1"), artifact("VERIFY", "x2", candidate_sha: "c" * 40, perspective: "auditor", covered_outcomes: ["outcome:greeting"]),
                 artifact("VERIFY", "x3", status: "superseded"), artifact("PUBLISH", "x4")]
    node = view("VERIFY", dependencies: ["BUILD"], attempts: attempts, artifacts: artifacts, blocked: {"VERIFY" => ["VERIFY already has an open attempt"], "PLAN" => ["no"]})
    expected = {"id" => "VERIFY", "status" => "active", "dependencies" => ["BUILD"],
                "attempts" => [{"attempt_id" => "a1", "iteration" => 1, "state" => "closed", "start_seq" => 4, "done_seq" => 5},
                               {"attempt_id" => "a2", "iteration" => 2, "state" => "open", "start_seq" => 6}],
                "blocked_reasons" => ["VERIFY already has an open attempt"],
                "artifacts" => [{"artifact_id" => "x2", "family" => "verification", "candidate_sha" => "c" * 40, "status" => "current",
                                 "perspective" => "auditor", "content_sha256" => "f" * 64, "covered_outcomes" => ["outcome:greeting"]},
                                {"artifact_id" => "x3", "family" => "verification", "candidate_sha" => nil, "status" => "superseded",
                                 "perspective" => "author", "content_sha256" => "f" * 64, "covered_outcomes" => []}]}
    assert_equal JSON.pretty_generate(expected), JSON.pretty_generate(node.to_h)
    assert_equal JSON.pretty_generate(expected), JSON.pretty_generate(node.to_h), "asking twice gives the same answer"
  end

  def test_a_node_with_nothing_of_its_own_has_empty_lists_not_nulls
    expected = {"id" => "PLAN", "status" => "blocked", "dependencies" => %w[INVESTIGATE REPRODUCE], "attempts" => [], "blocked_reasons" => [], "artifacts" => []}
    assert_equal JSON.generate(expected), JSON.generate(view("PLAN", dependencies: %w[INVESTIGATE REPRODUCE], attempts: [closed("BUILD", "b1", 2)]).to_h)
  end

  def test_it_reads_what_it_is_given_without_changing_any_of_it
    given = progress(attempts: [closed("VERIFY", "a1", 4), attempt("VERIFY", "a2", 6)], artifacts: [artifact("VERIFY", "x1")], manifests: {"a1" => result("failed")},
                     questions: [{"attempt_id" => "a2"}], blocked: {"VERIFY" => ["waiting"]}, runnable: ["PLAN"])
    frozen = Progress.new(**given.to_h.transform_values { |held| deep_freeze(held) })
    node = Giraffe::NodeView.new("VERIFY", deep_freeze({"retired" => false}), deep_freeze(["BUILD"]), frozen)
    assert_equal "waiting_for_answers", node.to_h["status"]
  end
end
