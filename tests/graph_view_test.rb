# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../lib/giraffe/graph_view"

# What GraphView and `bin/giraffe` print for a run's graph, pinned so the view can be taken apart without changing a
# byte of it. JSON is compared as text, because Hash equality ignores key order and clients see the order. The
# contracts, the run and its store are real. Where a state is one the real coordinator reaches only after a whole
# run (a failed attempt, a failed validation), the coordinator is a stand-in that reports what the test chose.
class GraphViewTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "giraffe")
  GRAPH = JSON.parse(File.read(File.join(ROOT, "references", "execution-contract-v1.json"))).fetch("graph")
  POLICY = JSON.parse(File.read(File.join(ROOT, "references", "coordinator-policy-v1.json")))
  NODES = POLICY.fetch("nodes").keys
  QUIET = {"current_candidate" => nil, "terminal" => false, "runnable" => [], "blocked" => {}}.freeze
  COMMANDS = %w[answer resume cancel sync].freeze

  # Answers the three questions a GraphView asks of a run's coordinator.
  FakeCoordinator = Data.define(:policy, :state, :projection) do
    def read_view = {"state" => state, "projection" => projection}
    def snapshot = state
  end

  # The run under test with its coordinator replaced. Everything else is the real run's, so what GraphView asks of
  # the run's store and contracts is answered for real.
  class RunWithCoordinator < SimpleDelegator
    attr_reader :coordinator

    def initialize(run, coordinator)
      super(run)
      @coordinator = coordinator
    end
  end

  def setup
    @tmp = Dir.mktmpdir("giraffe-graph-view-test-")
    @repo = File.join(@tmp, "app")
    Dir.mkdir(@repo)
    @run = Giraffe::Run.start(config, {"id" => "DEMO-1", "title" => "Show a greeting", "description" => "Show hello."})
  end

  def teardown = FileUtils.remove_entry(@tmp)

  def config
    Giraffe::Config.new(Giraffe::Config::DEFAULTS.merge(
      "store" => "local", "repo" => @repo, "runs_dir" => File.join(@tmp, "runs"), "github_repo" => "example/app",
      "checks" => [[RbConfig.ruby, "-e", "exit 0"]], "spec_command" => [RbConfig.ruby, "{spec}"], "runner" => "scripted"))
  end

  def assert_same_json(expected, actual, message = nil) = assert_equal(JSON.pretty_generate(expected), JSON.pretty_generate(actual), message)

  # A state as the real coordinator reports it, with the attempts keyed by ID in the order given.
  def state_of(attempts: [], artifacts: [], manifests: {}, events: 1)
    {"events" => Array.new(events) { |index| {"seq" => index + 1} }, "attempts" => attempts.to_h { |row| [row["attempt_id"], row] },
     "artifacts" => artifacts, "manifests" => manifests}
  end

  def attempt(node, id, start_seq, state: "open", **more)
    {"attempt_id" => id, "node" => node, "iteration" => 1, "label" => "pg-#{node}", "state" => state, "start_seq" => start_seq}.merge(more.transform_keys(&:to_s))
  end

  def closed(node, id, start_seq, **more) = attempt(node, id, start_seq, state: "closed", done_seq: start_seq + 1, **more)
  def manifest(state) = {"lease" => {}, "result" => {"state" => state}}

  def artifact(node, id, family: "verification", **more)
    {"family" => family, "node" => node, "attempt_id" => "a-#{node}", "producer" => "giraffe-harness", "input_sha" => "0" * 40, "candidate_sha" => nil,
     "content_type" => "application/json", "wake_id" => nil, "perspective" => "author", "covered_outcomes" => [], "e" => "artifact",
     "artifact_id" => id, "content_ref" => "run.artifacts/#{id}.blob", "content_sha256" => "f" * 64, "content_bytes" => 12, "v" => 1, "seq" => 1,
     "ts" => "2026-11-03T00:00:00Z", "status" => "current"}.merge(more.transform_keys(&:to_s))
  end

  # A GraphView over @run whose coordinator reports this state, this policy, and a projection that is the quiet one
  # with the given entries on top.
  def view_of(state = state_of, policy: POLICY, **projection)
    Giraffe::GraphView.new(RunWithCoordinator.new(@run, FakeCoordinator.new(policy, state, QUIET.merge(projection))))
  end

  def row(snapshot, node) = snapshot["nodes"].find { |candidate| candidate["id"] == node }

  def status_of(node, attempts: [], runnable: [], manifests: {})
    row(view_of(state_of(attempts: attempts, manifests: manifests), "runnable" => runnable).snapshot, node)["status"]
  end

  def definition = {"nodes" => POLICY["nodes"], "dependencies" => GRAPH["dependencies"], "legal_edges" => GRAPH["legal_edges"]}

  def quiet_row(name, status: nil, **fields)
    {"id" => name, "status" => status || (POLICY["nodes"][name]["retired"] ? "retired" : "blocked"), "dependencies" => GRAPH["dependencies"][name],
     "attempts" => [], "blocked_reasons" => [], "artifacts" => []}.merge(fields.transform_keys(&:to_s))
  end

  def asking(attempt_id) = [{"id" => "q1", "text" => "Which greeting?", "role" => "build", "attempt_id" => attempt_id}]

  def test_a_node_nobody_started_is_runnable_when_the_projection_says_so_and_otherwise_blocked_or_retired
    assert_equal "blocked", status_of("BUILD")
    assert_equal "runnable", status_of("BUILD", runnable: ["BUILD"])
    assert_equal "retired", status_of("SELF-REVIEW")
    assert_equal "runnable", status_of("SELF-REVIEW", runnable: ["SELF-REVIEW"]), "runnable outranks retired"
  end

  def test_an_open_attempt_makes_its_node_active_whatever_else_the_projection_says
    assert_equal "active", status_of("BUILD", attempts: [attempt("BUILD", "a1", 4)])
    assert_equal "active", status_of("BUILD", attempts: [attempt("BUILD", "a1", 4)], runnable: ["BUILD"])
    assert_equal "active", status_of("SELF-REVIEW", attempts: [attempt("SELF-REVIEW", "a2", 5)])
  end

  def test_an_open_attempt_shows_the_run_status_only_when_the_run_is_paused_or_cancelled
    %w[paused cancelled].each do |status|
      @run.update(status: status)
      assert_equal status, status_of("BUILD", attempts: [attempt("BUILD", "a1", 4)])
      assert_equal "blocked", status_of("PLAN"), "a node without an open attempt keeps its own status"
    end
    %w[running waiting_for_answers draft_pr].each do |status|
      @run.update(status: status)
      assert_equal "active", status_of("BUILD", attempts: [attempt("BUILD", "a1", 4)], runnable: [])
    end
  end

  def test_an_open_attempt_with_a_question_of_its_own_waits_for_answers
    @run.update(status: "waiting_for_answers", questions: asking("a1"))
    assert_equal "waiting_for_answers", status_of("BUILD", attempts: [attempt("BUILD", "a1", 4)])
    assert_equal "active", status_of("BUILD", attempts: [attempt("BUILD", "a9", 4)]), "a question about another attempt is not this node's"
    @run.update(status: "paused")
    assert_equal "paused", status_of("BUILD", attempts: [attempt("BUILD", "a1", 4)]), "a stopped run outranks a question"
  end

  def test_a_node_whose_newest_attempt_closed_is_completed_unless_that_attempt_failed
    attempts = [closed("VERIFY", "a1", 4)]
    assert_equal "completed", status_of("VERIFY", attempts: attempts)
    assert_equal "completed", status_of("VERIFY", attempts: attempts, manifests: {"a1" => manifest("completed")})
    assert_equal "completed", status_of("VERIFY", attempts: attempts, manifests: {"a1" => manifest("something_else")})
    assert_equal "completed", status_of("VERIFY", attempts: attempts, manifests: {"a1" => {"lease" => {}, "result" => nil}})
    assert_equal "failed", status_of("VERIFY", attempts: attempts, manifests: {"a1" => manifest("failed")})
    assert_equal "failed", status_of("VERIFY", attempts: attempts, manifests: {"a1" => manifest("mutation_violation")})
    assert_equal "completed", status_of("SELF-REVIEW", attempts: [closed("SELF-REVIEW", "a3", 4)]), "retired only describes a node nobody ran"
  end

  def test_a_state_without_manifests_leaves_a_closed_node_completed
    state = state_of(attempts: [closed("VERIFY", "a1", 4)]).tap { |held| held.delete("manifests") }
    assert_equal "completed", row(view_of(state).snapshot, "VERIFY")["status"]
  end

  def test_a_closed_node_the_projection_makes_runnable_again_is_runnable
    attempts = [closed("VERIFY", "a1", 4)]
    assert_equal "runnable", status_of("VERIFY", attempts: attempts, runnable: ["VERIFY"], manifests: {"a1" => manifest("failed")})
  end

  def test_the_newest_attempt_by_start_seq_decides_not_the_order_they_are_listed_in
    older, newer = closed("VERIFY", "a1", 4), attempt("VERIFY", "a2", 6)
    assert_equal "active", status_of("VERIFY", attempts: [newer, older])
    assert_equal "active", status_of("VERIFY", attempts: [older, newer])
    finished = closed("VERIFY", "a2", 6)
    assert_equal "completed", status_of("VERIFY", attempts: [finished, older], manifests: {"a1" => manifest("failed"), "a2" => manifest("completed")})
    assert_equal "failed", status_of("VERIFY", attempts: [older, finished], manifests: {"a1" => manifest("completed"), "a2" => manifest("failed")})
  end

  def test_a_node_lists_its_attempts_oldest_first_with_only_the_published_fields_and_its_artifacts_with_theirs
    attempts = [attempt("VERIFY", "a2", 6, iteration: 2, lease_id: "l2"), closed("VERIFY", "a1", 4, lease_id: "l1"), closed("BUILD", "b1", 2)]
    artifacts = [artifact("BUILD", "x1"), artifact("VERIFY", "x2", candidate_sha: "c" * 40, perspective: "auditor", covered_outcomes: ["outcome:greeting"]),
                 artifact("VERIFY", "x3", status: "superseded"), artifact("PUBLISH", "x4")]
    reasons = {"VERIFY" => ["VERIFY already has an open attempt"]}
    snapshot = view_of(state_of(attempts: attempts, artifacts: artifacts), "blocked" => reasons).snapshot
    expected = {"id" => "VERIFY", "status" => "active", "dependencies" => ["BUILD"],
                "attempts" => [{"attempt_id" => "a1", "iteration" => 1, "state" => "closed", "start_seq" => 4, "done_seq" => 5},
                               {"attempt_id" => "a2", "iteration" => 2, "state" => "open", "start_seq" => 6}],
                "blocked_reasons" => ["VERIFY already has an open attempt"],
                "artifacts" => [{"artifact_id" => "x2", "family" => "verification", "candidate_sha" => "c" * 40, "status" => "current",
                                 "perspective" => "auditor", "content_sha256" => "f" * 64, "covered_outcomes" => ["outcome:greeting"]},
                                {"artifact_id" => "x3", "family" => "verification", "candidate_sha" => nil, "status" => "superseded",
                                 "perspective" => "author", "content_sha256" => "f" * 64, "covered_outcomes" => []}]}
    assert_same_json expected, row(snapshot, "VERIFY")
    assert_same_json quiet_row("PLAN"), row(snapshot, "PLAN"), "a node with nothing of its own has empty lists, not nulls"
    assert_equal %w[b1], row(snapshot, "BUILD")["attempts"].map { |held| held["attempt_id"] }
  end

  def test_the_snapshot_publishes_the_run_the_graph_and_the_projection_in_the_published_order
    @run.update(status: "paused", error: "VERIFY failed", questions: asking("a1"))
    sync = {"mode" => "mirrored", "synced" => true, "revision" => 2, "event_seq" => 3}
    File.write(Giraffe::LocalStore.sibling(@run.path, ".sync.json"), JSON.generate(sync))
    snapshot = view_of(state_of(events: 3), "current_candidate" => "c" * 40, "terminal" => true, "validation_error" => "a gate is open").snapshot
    expected = {"schema_version" => 1, "run_id" => @run.id, "revision" => @run.state["revision"], "cursor" => 3, "status" => "paused",
                "graph_version" => Digest::SHA256.hexdigest(JSON.generate(definition)), "definition" => definition, "candidate_sha" => "c" * 40,
                "terminal" => true, "nodes" => NODES.map { |name| quiet_row(name) }, "validation_error" => "a gate is open",
                "questions" => asking("a1"), "error" => "VERIFY failed", "storage" => sync, "commands" => COMMANDS, "graph_editing" => false}
    assert_same_json expected, snapshot
  end

  def test_a_projection_without_a_validation_error_publishes_null_and_one_with_it_blocks_every_node
    assert_nil view_of.snapshot.fetch("validation_error")
    reason = "coordinator policy nodes do not match execution graph"
    blocked = NODES.to_h { |name| [name, [reason]] }
    snapshot = view_of(state_of, "runnable" => [], "blocked" => blocked, "validation_error" => reason).snapshot
    assert_equal reason, snapshot["validation_error"]
    assert_same_json NODES.map { |name| quiet_row(name, blocked_reasons: [reason]) }, snapshot["nodes"]
  end

  def test_the_definition_is_the_policy_nodes_with_the_contract_dependencies_and_edges_and_its_version_is_their_digest
    snapshot = view_of.snapshot
    assert_equal %w[nodes dependencies legal_edges], snapshot["definition"].keys
    assert_equal JSON.generate(definition), JSON.generate(snapshot["definition"])
    assert_equal Digest::SHA256.hexdigest(JSON.generate(definition)), snapshot["graph_version"]
    assert_match(/\A\h{64}\z/, snapshot["graph_version"])
  end

  def test_the_policy_decides_which_nodes_there_are_and_in_what_order
    policy = POLICY.merge("nodes" => POLICY["nodes"].to_a.reverse.to_h)
    snapshot = view_of(state_of, policy: policy).snapshot
    assert_equal NODES.reverse, snapshot["nodes"].map { |held| held["id"] }
    assert_equal NODES.reverse, snapshot["definition"]["nodes"].keys
    refute_equal view_of.snapshot["graph_version"], snapshot["graph_version"]
    expected = {"nodes" => policy["nodes"], "dependencies" => GRAPH["dependencies"], "legal_edges" => GRAPH["legal_edges"]}
    assert_equal Digest::SHA256.hexdigest(JSON.generate(expected)), snapshot["graph_version"]
  end

  def test_a_policy_node_the_contract_does_not_declare_is_an_error_not_a_node_without_dependencies
    policy = POLICY.merge("nodes" => POLICY["nodes"].merge("EXTRA" => {"inputs" => [], "outputs" => []}))
    error = assert_raises(KeyError) { view_of(state_of, policy: policy).snapshot }
    assert_includes error.message, "EXTRA"
  end

  def test_a_fresh_run_has_its_first_node_runnable_and_the_rest_blocked_or_retired
    snapshot = Giraffe::GraphView.new(@run).snapshot
    assert_same_json expected_snapshot(statuses: {"TRIAGE" => "runnable"}), snapshot
    assert_equal [1, 1, "running"], snapshot.values_at("revision", "cursor", "status")
  end

  def test_an_attempt_in_progress_is_active_then_waiting_then_paused_then_cancelled
    id = @run.coordinator.start("TRIAGE").fetch("attempt_id")
    running = [{"attempt_id" => id, "iteration" => 1, "state" => "open", "start_seq" => 2}]
    view = Giraffe::GraphView.new(@run)
    assert_same_json expected_snapshot(statuses: {"TRIAGE" => "active"}, attempts: {"TRIAGE" => running}), view.snapshot
    @run.update(status: "waiting_for_answers", questions: asking(id))
    assert_same_json expected_snapshot(statuses: {"TRIAGE" => "waiting_for_answers"}, attempts: {"TRIAGE" => running}), view.snapshot
    @run.update(status: "paused")
    assert_same_json expected_snapshot(statuses: {"TRIAGE" => "paused"}, attempts: {"TRIAGE" => running}), view.snapshot
    @run.cancel
    assert_same_json expected_snapshot(statuses: {"TRIAGE" => "cancelled"}, attempts: {"TRIAGE" => running}), view.snapshot
    assert_equal ["cancelled", "Cancellation requested by the operator"], view.snapshot.values_at("status", "error")
  end

  def test_a_completed_node_shows_its_closed_attempt_and_artifact_and_unlocks_what_depends_on_it
    attempt_id, artifact_id = complete_triage
    done = [{"attempt_id" => attempt_id, "iteration" => 1, "state" => "closed", "start_seq" => 2, "done_seq" => 3}]
    held = [{"artifact_id" => artifact_id, "family" => "triage_brief", "candidate_sha" => nil, "status" => "current", "perspective" => "author",
             "content_sha256" => Digest::SHA256.hexdigest(JSON.generate(triage_brief)), "covered_outcomes" => []}]
    statuses = {"TRIAGE" => "completed", "INVESTIGATE" => "runnable", "WORKTREE" => "runnable"}
    snapshot = Giraffe::GraphView.new(@run).snapshot
    assert_same_json expected_snapshot(statuses: statuses, attempts: {"TRIAGE" => done}, artifacts: {"TRIAGE" => held}), snapshot
    assert_equal 3, snapshot["cursor"]
  end

  def test_events_return_the_log_after_a_cursor_with_the_cursor_they_reached
    complete_triage
    logged = File.readlines(@run.path).map { |line| JSON.parse(line) }
    view = Giraffe::GraphView.new(@run)
    [0, 1, 2, logged.length].each do |after|
      expected = {"schema_version" => 1, "run_id" => @run.id, "revision" => @run.state["revision"], "after" => after, "cursor" => logged.length,
                  "events" => logged.drop(after)}
      assert_same_json expected, view.events(after: after), "after #{after}"
    end
    assert_same_json view.events(after: 0), view.events
    assert_equal 3, logged.length
  end

  def test_events_come_from_the_coordinators_snapshot_of_the_log_which_has_been_validated
    expected = {"schema_version" => 1, "run_id" => @run.id, "revision" => @run.state["revision"], "after" => 1, "cursor" => 3,
                "events" => [{"seq" => 2}, {"seq" => 3}]}
    assert_same_json expected, view_of(state_of(events: 3)).events(after: 1)
  end

  def test_events_refuse_a_cursor_that_is_not_a_nonnegative_integer_or_is_ahead_of_the_run
    view = Giraffe::GraphView.new(@run)
    [-1, 1.5, "1", nil, :one].each do |after|
      error = assert_raises(Giraffe::Error, "after #{after.inspect}") { view.events(after: after) }
      assert_equal [Giraffe::Error, "event cursor must be a nonnegative integer"], [error.class, error.message]
    end
    error = assert_raises(Giraffe::Error) { view.events(after: 2) }
    assert_equal [Giraffe::Error, "event cursor is ahead of the run"], [error.class, error.message]
    assert_empty view.events(after: 1)["events"], "a cursor at the end of the log is not ahead of it"
  end

  def test_the_graph_command_prints_the_snapshot_as_pretty_json
    complete_triage
    printed = Giraffe::GraphView.new(Giraffe::Run.load(@run.path)).snapshot
    assert_equal [JSON.pretty_generate(printed) + "\n", "", 0], cli("graph", @run.path)
    assert_equal "completed", row(printed, "TRIAGE")["status"], "the printed run is not an empty one"
  end

  def test_the_status_command_wraps_the_snapshot_with_the_runs_own_fields
    @run.update(status: "paused", error: "VERIFY failed", questions: asking("a1"))
    graph = Giraffe::GraphView.new(Giraffe::Run.load(@run.path)).snapshot
    printed = {"path" => @run.path, "status" => "paused", "questions" => asking("a1"), "error" => "VERIFY failed", "cancel_requested" => false,
               "graph" => graph, "sync" => graph["storage"]}
    assert_equal [JSON.pretty_generate(printed) + "\n", "", 0], cli("status", @run.path)
    assert_equal({"mode" => "local", "synced" => false}, graph["storage"])
  end

  def test_the_events_command_prints_events_after_a_cursor_and_the_first_error_as_one_json_line
    complete_triage
    view = Giraffe::GraphView.new(Giraffe::Run.load(@run.path))
    assert_equal [JSON.pretty_generate(view.events) + "\n", "", 0], cli("events", @run.path)
    assert_equal [JSON.pretty_generate(view.events(after: 2)) + "\n", "", 0], cli("events", @run.path, "--after", "2")
    assert_equal ["", JSON.generate("path" => @run.path, "error" => "event cursor is ahead of the run") + "\n", 1], cli("events", @run.path, "--after", "4")
    assert_equal ["", JSON.generate("path" => @run.path, "error" => "event cursor must be a nonnegative integer") + "\n", 1], cli("events", @run.path, "--after", "-1")
  end

  private

  def cli(*args)
    out, err, status = Open3.capture3(RbConfig.ruby, BIN, *args)
    [out, err, status.exitstatus]
  end

  # A snapshot of @run written out from the contracts and the run's own fields, not by GraphView. `statuses`,
  # `attempts` and `artifacts` map a node to what differs from a node nobody has started.
  def expected_snapshot(statuses: {}, attempts: {}, artifacts: {})
    view = @run.coordinator.read_view
    reasons = view["projection"]["blocked"]
    nodes = NODES.map do |name|
      quiet_row(name, status: statuses[name], attempts: attempts.fetch(name, []), blocked_reasons: reasons[name] || [], artifacts: artifacts.fetch(name, []))
    end
    {"schema_version" => 1, "run_id" => @run.id, "revision" => @run.state["revision"], "cursor" => File.foreach(@run.path).count,
     "status" => @run.state["status"], "graph_version" => Digest::SHA256.hexdigest(JSON.generate(definition)), "definition" => definition,
     "candidate_sha" => view["projection"]["current_candidate"], "terminal" => view["projection"]["terminal"], "nodes" => nodes, "validation_error" => nil,
     "questions" => @run.state["questions"], "error" => @run.state["error"], "storage" => {"mode" => "local", "synced" => false},
     "commands" => COMMANDS, "graph_editing" => false}
  end

  def triage_brief
    clauses = %w[outcome:greeting constraint:input]
    {"questions" => [], "summary" => "A requested greeting change", "ui" => false, "bug" => false, "ticket" => @run.state["ticket"], "outcome_register" => {
      "why" => "People need the requested greeting.", "actors" => [{"id" => "actor:user", "situation" => "A person reading a greeting."}],
      "positive_postconditions" => [{"id" => clauses[0], "statement" => "People see the requested greeting."}],
      "negative_face" => [{"id" => clauses[1], "statement" => "Existing input remains readable."}], "declared_gaps" => []}}
  end

  # Runs TRIAGE through the real coordinator and returns the attempt's ID and its artifact's.
  def complete_triage
    attempt_id = @run.coordinator.start("TRIAGE").fetch("attempt_id")
    saved = @run.coordinator.put_artifact({"family" => "triage_brief", "node" => "TRIAGE", "attempt_id" => attempt_id, "producer" => "giraffe-harness",
                                           "input_sha" => "0" * 40, "candidate_sha" => nil, "content_type" => "application/json", "wake_id" => nil,
                                           "perspective" => "author", "covered_outcomes" => []}, JSON.generate(triage_brief))
    @run.coordinator.complete("TRIAGE", attempt_id)
    [attempt_id, saved.fetch("artifact_id")]
  end
end
