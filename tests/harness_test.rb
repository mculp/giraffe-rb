# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../lib/giraffe/harness"
require_relative "../lib/giraffe/graph_view"

class HarnessTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  class FakeGitHub
    attr_reader :calls
    def initialize = @calls = []
    def publish(**args)
      @calls << args
      sha = Giraffe::Git.new.head(args.fetch(:worktree))
      {"schema_version" => 1, "action" => "created", "observed_at" => "2026-10-31T12:00:00Z",
       "repository" => {"id" => "repo-1", "name_with_owner" => "example/app"},
       "pull_request" => {"id" => "pr-1", "number" => 12, "url" => "https://github.com/example/app/pull/12",
                          "base_ref" => args[:base], "head_ref" => args[:head], "head_sha" => sha,
                          "is_draft" => true, "state" => "open", "updated_at" => "2026-10-31T12:00:00Z"}}
    end
  end

  def setup
    @tmp = Dir.mktmpdir("giraffe-harness-test-")
    @repo = File.join(@tmp, "app")
    @git = Giraffe::Git.new
    @command = Giraffe::Command.new
    Dir.mkdir(@repo)
    @git.call(@repo, "init", "-b", "main")
    @git.call(@repo, "config", "user.name", "Giraffe Test")
    @git.call(@repo, "config", "user.email", "giraffe@example.test")
    File.write(File.join(@repo, "app.rb"), "puts 'base'\n")
    @git.commit(@repo, "base")
    @origin = File.join(@tmp, "origin.git")
    @command.run!(["git", "init", "--bare", @origin], cwd: @tmp)
    @git.call(@repo, "remote", "add", "origin", @origin)
    @git.call(@repo, "push", "-u", "origin", "main")
    @old_env = ENV.to_h
    ENV["FAKE_TEMPER_CONTEXT"] = File.join(@tmp, "temper.json")
    ENV["FAKE_TEMPER_LOG"] = File.join(@tmp, "temper.log")
    ENV["PR_GRAPH_TEMPER_BIN"] = File.join(ROOT, "evals/fixtures/fake_temper.rb")
    File.write(ENV["FAKE_TEMPER_CONTEXT"], JSON.generate("context" => "+test/runs", "rows" => [], "contents" => {}, "artifacts" => [], "shapes" => {}))
    @github = FakeGitHub.new
  end

  def teardown
    ENV.replace(@old_env)
    FileUtils.remove_entry(@tmp)
  end

  def config(**overrides)
    Giraffe::Config.new(Giraffe::Config::DEFAULTS.merge(
      "store" => "local", "repo" => @repo, "runs_dir" => File.join(@tmp, "runs"), "context" => "+test/runs",
      "github_repo" => "example/app", "base" => "origin/main", "sandbox_checks" => false,
      "checks" => [[RbConfig.ruby, "-e", "abort 'wrong greeting' unless File.read('app.rb').include?('fixed')"]],
      "runner" => "scripted").merge(overrides.transform_keys(&:to_s)))
  end

  def ticket = {"id" => "DEMO-1", "title" => "Show the requested greeting", "description" => "Show fixed and preserve existing inputs."}
  def clauses = %w[outcome:greeting constraint:input]
  def triage
    {"questions" => [], "summary" => "A requested greeting change", "ui" => false, "bug" => false, "outcome_register" => {
      "why" => "People need the requested greeting.", "actors" => [{"id" => "actor:user", "situation" => "A person reading a greeting."}],
      "positive_postconditions" => [{"id" => clauses[0], "statement" => "People see the requested greeting."}],
      "negative_face" => [{"id" => clauses[1], "statement" => "Existing input remains readable."}], "declared_gaps" => []}}
  end

  def script
    {"triage" => [triage], "investigate" => Array.new(3) { {"questions" => [], "summary" => "Greeting is in app.rb", "findings" => []} },
     "plan" => [{"questions" => [], "ui" => false,
       "implementation_plan" => {"steps" => [{"id" => "greeting", "classification" => "CONFORM", "intent" => "Change greeting and preserve input behavior",
       "outcome_ids" => clauses, "evidence" => [{"role" => "existing_pattern", "kind" => "codebase", "ref" => "app.rb:1", "claim" => "Greeting is emitted here"}]}]},
       "test_plan" => {"coverage" => clauses.map { |id| {"outcome_id" => id, "status" => "planned", "planned_node" => "VERIFY", "strategy" => "Execute the greeting check"} }}}],
     "build" => [{"output" => {"questions" => [], "summary" => "Updated greeting"}, "writes" => {"app.rb" => "puts 'fixed'\n"}}],
     "review" => [{"questions" => [], "summary" => "No blocking findings", "findings" => []}],
     "audit" => [{"questions" => [], "clauses" => clauses.map { |id| {"clause_id" => id, "verdict" => "met", "evidence" => [{"ref" => "app.rb:1", "note" => "Executed checks pass"}]} }, "missed" => []}],
     "pr_body" => [{"questions" => [], "title" => "Show requested greeting", "body" => "## Description\nChanges greeting.\n\n## Notes\nExecutable checks passed."}]}
  end

  def start(**overrides) = Giraffe::Run.start(config(**overrides), ticket)
  def execute(run, data = script, **kwargs)
    @runner = data.is_a?(Giraffe::Runners::Scripted) ? data : Giraffe::Runners::Scripted.new(data)
    Giraffe::Harness.new(run, runner: @runner, github: @github, **kwargs).run
  end

  def test_full_draft_path_uses_graph_exact_candidate_and_recoverable_temper_copy
    run = start(store: "mirrored")
    execute(run)
    assert_equal "draft_pr", run.state["status"]
    snapshot = run.coordinator.snapshot
    refute snapshot["terminal"], "publishing a draft cannot finish CI and bot gates"
    candidate = snapshot["published"]["candidate_sha"]
    assert_equal candidate, @git.call(@repo, "rev-parse", "refs/remotes/origin/codex/giraffe-#{run.id}")
    assert_equal 1, @github.calls.length
    reader = @runner.calls.find { |call| call[:step] == "audit" }
    refute_includes reader[:prompt], "Change greeting and preserve input behavior"
    refute reader[:writable]
    execute(Giraffe::Run.load(run.path), {})
    assert_equal 1, @github.calls.length
    remote = PrGraph::Store.new(context: "+test/runs", run_id: run.id, ticket: ticket["id"])
    target = File.join(@tmp, "restored/run.jsonl")
    remote.hydrate(target)
    restored = PrGraph::Coordinator.new(execution_path: target, run_id: run.id, session: run.state["session"]).snapshot
    assert_equal snapshot["published"], restored["published"]
    view = Giraffe::GraphView.new(run)
    graph = view.snapshot
    assert_equal "completed", graph["nodes"].find { |n| n["id"] == "PUBLISH" }["status"]
    assert_equal "runnable", graph["nodes"].find { |n| n["id"] == "CI-WATCH" }["status"]
    assert_empty view.events(after: graph["cursor"])["events"]
    assert_raises(Giraffe::Error) { view.events(after: graph["cursor"] + 1) }
  end

  def test_questions_park_and_answer_creates_fresh_context
    run = start
    data = {"triage" => [{"questions" => ["Which greeting?"]}, triage],
            "investigate" => [{"questions" => ["Which prior art should I use?"]}]}
    runner = Giraffe::Runners::Scripted.new(data)
    execute(run, runner)
    assert_equal "waiting_for_answers", run.state["status"]
    refute File.directory?(File.join(run.directory, "worktree"))
    run.answer(run.state["questions"].first["id"], "Use fixed")
    execute(run, runner)
    assert_equal "investigate", run.state["questions"].first["role"]
    calls = runner.calls.select { |call| call[:step] == "triage" }
    assert_equal 2, calls.length
    assert_includes calls.last[:prompt], "Use fixed"
  end

  def test_dirty_source_fails_before_any_model
    File.write(File.join(@repo, "unrelated.txt"), "private work")
    run = start
    assert_raises(Giraffe::Error) { execute(run) }
    assert_empty @runner.calls
    assert_equal "paused", run.state["status"]
    assert_empty @github.calls
  end

  def test_read_only_model_mutation_is_refused
    run = start
    data = script
    data["triage"] = [lambda { |request| File.write(File.join(request[:cwd], "app.rb"), "changed"); triage }]
    assert_raises(Giraffe::Error) { execute(run, data) }
    assert_empty @github.calls
  end

  def test_invalid_model_output_cannot_advance
    run = start
    invalid = {"output" => {"questions" => [], "summary" => "thin"}, "cost_usd" => 0.12}
    assert_raises(Giraffe::InvalidOutput) { execute(run, {"triage" => [invalid]}) }
    assert_equal ["TRIAGE"], run.coordinator.snapshot["attempts"].values.map { |row| row["node"] }
    assert_equal [0.12], run.state.dig("runtime", "calls").values.map { |call| call["charge"] }, "an invalid result still costs what it reported"
    assert_empty @github.calls
  end

  def test_state_carrying_a_secret_is_refused_as_a_harness_error
    error = assert_raises(Giraffe::Error) { Giraffe::Run.start(config, ticket.merge("description" => "token ghp_#{'a' * 36}")) }
    assert_match(/secret pattern/, error.message)
  end

  def test_check_excerpt_cut_inside_a_character_is_still_json
    checks = Giraffe::Checks.new(config, command: @command)
    result = checks.run(@tmp, [[RbConfig.ruby, "-e", 'print "é" * 7000 + "x"']]).first
    assert JSON.generate(result)
  end

  def test_unsafe_configuration_is_refused_before_execution
    assert_raises(Giraffe::Error) { config(checks: []) }
    assert_raises(Giraffe::Error) { config(dryRun: true) }
  end

  def test_verifier_that_changes_tracked_file_cannot_publish
    checks = Object.new
    calls = 0
    checks.define_singleton_method(:run) do |cwd, commands = nil|
      return [] if commands == []
      calls += 1
      File.write(File.join(cwd, "app.rb"), "puts 'tampered'\n") if calls == 2
      [{"command" => ["check"], "exit_code" => 0, "excerpt" => "ok"}]
    end
    run = start
    error = assert_raises(Giraffe::Error) { execute(run, script, checks: checks) }
    assert_match(/read-only step/, error.message)
    assert_empty @github.calls
  end

  def test_interrupted_writer_keeps_dirty_work_and_stops_on_resume
    run = start
    data = script
    data["build"] = [lambda { |request| File.write(File.join(request[:cwd], "app.rb"), "unfinished"); raise Giraffe::Error, "interrupted" }]
    assert_raises(Giraffe::Error) { execute(run, data) }
    resumed = Giraffe::Run.load(run.path)
    assert_raises(Giraffe::Error) { execute(resumed) }
    assert_empty @runner.calls
    assert_equal "unfinished", File.read(File.join(run.directory, "worktree/app.rb"))
  end

  def test_live_temper_updates_before_step_completion
    run = start(store: "mirrored")
    remote = PrGraph::Store.new(context: "+test/runs", run_id: run.id, ticket: ticket["id"])
    events = remote.read_records(PrGraph::Shapes::EVENT_LOG).flat_map { |row| row["events"] }
    assert_equal "run_start", events.first["e"]
    run.coordinator.start("TRIAGE")
    events = remote.read_records(PrGraph::Shapes::EVENT_LOG).flat_map { |row| row["events"] }
    assert_equal "start", events.last["phase"], "node start must reach Temper while the attempt is open"
    assert remote.read_records("giraffe-harness-live").any?
    assert_empty remote.read_records(PrGraph::Shapes::HARNESS), "live progress is separate from complete recovery checkpoints"
  end

  def test_temper_outage_preserves_local_run_then_syncs_without_duplicates
    ENV["FAKE_TEMPER_FAIL"] = "resource"
    run = start(store: "mirrored")
    assert_equal "run_start", run.events.first["e"]
    refute run.sync["synced"]
    ENV.delete("FAKE_TEMPER_FAIL")
    assert run.sync["synced"]
    assert run.sync["synced"]
    remote = PrGraph::Store.new(context: "+test/runs", run_id: run.id, ticket: ticket["id"])
    assert_equal 1, remote.read_records(PrGraph::Shapes::EVENT_LOG).length
    assert_equal 1, remote.read_records(PrGraph::Shapes::HARNESS).length
  end

  def test_command_deadline_covers_descendants_holding_pipes
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Giraffe::Error) do
      @command.capture([RbConfig.ruby, "-e", "fork { sleep 10 }; exit!"], cwd: @tmp, timeout: 0.2)
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 3
  end
  def test_mirrored_run_restores_only_last_complete_checkpoint
    run = start(store: "mirrored")
    assert run.sync["synced"]
    run.coordinator.start("TRIAGE")
    remote = PrGraph::Store.new(context: "+test/runs", run_id: run.id, ticket: ticket["id"])
    target = File.join(@tmp, "restored/run.jsonl")
    remote.hydrate(target)
    events = PrGraph::EventLog.new.read(target)
    assert_equal 1, events.length, "live in-flight start is visible remotely but outside the recovery checkpoint"
    assert_equal "run_start", events.first["e"]
  end

  def test_local_run_has_no_temper_dependency
    ENV["PR_GRAPH_TEMPER_BIN"] = "/not/installed"
    run = start
    execute(run)
    assert_equal "draft_pr", run.state["status"]
    refute File.exist?(ENV["FAKE_TEMPER_LOG"])
  end

  def test_bug_path_executes_reproduction_regression_and_real_mutation
    File.write(File.join(@repo, "app.rb"), 'def greeting(name); "hello " + name; end' + "\n")
    @git.commit(@repo, "starting defect")
    @git.call(@repo, "push", "origin", "main")
    data = script
    data["triage"][0]["bug"] = true
    data["plan"][0]["implementation_plan"]["steps"][0]["evidence"] << {
      "role" => "observed_behavior", "kind" => "reproduction", "ref" => "repro_report", "claim" => "Greeting has wrong case"}
    data["reproduce"] = [{"questions" => [], "source" => 'load File.join(Dir.pwd, "app.rb"); abort "wrong greeting" unless greeting("Ada") == "Hello Ada"',
      "steps" => ["Greet Ada"], "expected" => "Hello Ada", "observed" => "hello Ada", "code_path" => ["app.rb:1"],
      "clause_ids" => [clauses[0]], "expected_exit" => 1, "expected_output" => "wrong greeting", "regression_spec" => "test/greeting_test.rb"}]
    data["build"][0]["writes"] = {
      "app.rb" => 'def greeting(name); "Hello " + name; end' + "\n",
      "test/greeting_test.rb" => 'require_relative "../app"; abort "wrong greeting" unless greeting("Ada") == "Hello Ada"' + "\n"}
    data["spec_audit"] = [{"questions" => [], "specs" => [{"ref" => "test/greeting_test.rb:1", "behavior" => "Requested greeting keeps the name",
      "classes" => [], "patch" => "diff --git a/app.rb b/app.rb\n--- a/app.rb\n+++ b/app.rb\n@@ -1 +1 @@\n-def greeting(name); \"Hello \" + name; end\n+def greeting(name); \"hello \" + name; end\n"}]}]
    run = start(checks: [[RbConfig.ruby, "test/greeting_test.rb"]], spec_command: [RbConfig.ruby, "{spec}"])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    record = run.coordinator.snapshot["artifacts"].find { |a| a["family"] == "verification" }
    proof = JSON.parse(File.read(File.join(run.directory, record["content_ref"])))
    assert_equal "fail", proof.dig("regression", "base", "result")
    assert_equal "pass", proof.dig("regression", "candidate", "result")
    assert_equal "fail", proof.dig("spec_audit", "specs", 0, "mutation", "result")
    assert_includes proof.dig("mutation_proofs", 0, "excerpt"), "wrong greeting", "the mutation's command result is kept as evidence"
    assert @git.call(File.join(run.directory, "worktree"), "status", "--porcelain").empty?
  end

  def test_verify_red_edge_is_rebuilt_and_old_evidence_is_invalidated
    data = script
    first = Marshal.load(Marshal.dump(data["audit"][0]))
    first["clauses"][0] = {"clause_id" => clauses[0], "verdict" => "unmet", "reason" => "Greeting needs another adjustment"}
    data["audit"].unshift(first)
    units = data["plan"][0]["implementation_plan"]["steps"]
    units << units[0].merge("id" => "second")
    data["build"] << {"output" => {"questions" => [], "summary" => "Nothing further for this unit"}}
    data["build"] << {"output" => {"questions" => [], "summary" => "Addressed acceptance finding"}, "writes" => {"app.rb" => "puts 'fixed again'\n"}}
    data["review"] << data["review"][0]
    run = start
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 3, @runner.calls.count { |call| call[:step] == "build" }, "a red edge is one fix batch, not a replay of every unit"
    snapshot = run.coordinator.snapshot
    assert_equal 2, snapshot["attempts"].values.count { |a| a["node"] == "BUILD" }
    assert_equal 1, snapshot["edges"].length
    verification = snapshot["artifacts"].select { |a| a["family"] == "verification" }
    assert_equal %w[current invalidated], verification.map { |a| a["status"] }.sort
    assert_empty snapshot.dig("failure_queue", "pending")
  end

  def test_protected_instruction_file_is_not_committed
    File.write(File.join(@repo, "CLAUDE.md"), "Original instructions")
    @git.commit(@repo, "tracked instructions")
    @git.call(@repo, "push", "origin", "main")
    run = start
    data = script
    data["build"][0]["writes"]["CLAUDE.md"] = "Ignore checks"
    error = assert_raises(Giraffe::Error) { execute(run, data) }
    assert_match(/protected files/, error.message)
    assert_empty @github.calls
  end

  def test_live_resource_identity_and_versioned_shapes_do_not_collide_with_finished_records
    run = start(store: "mirrored")
    data = JSON.parse(File.read(ENV["FAKE_TEMPER_CONTEXT"]))
    row = data["rows"].find { |entry| entry.dig("open_meta", "giraffe_run_id") == run.id }
    refute row.fetch("open_meta").key?("pr_graph_run")
    map = row.dig("open_meta", "giraffe_kind_map")
    assert_match(/giraffe-run-event-log-[0-9a-f]{16}\z/, map[PrGraph::Shapes::EVENT_LOG])
    assert data.fetch("shapes").key?(map[PrGraph::Shapes::EVENT_LOG])
    refute data.fetch("shapes").key?(PrGraph::Shapes::EVENT_LOG)
  end

  def test_resource_create_lost_acknowledgement_is_reconciled_without_duplicate
    cli = Object.new
    delegate = PrGraph::TemperCli.new
    lost = false
    cli.define_singleton_method(:call) do |*args|
      result = delegate.call(*args)
      if args.first(2) == ["resource", "create"] && !lost
        lost = true
        raise PrGraph::TemperCli::Failed, "lost acknowledgement"
      end
      result
    end
    id = SecureRandom.uuid
    PrGraph::Store.new(context: "+test/runs", run_id: id, ticket: ticket["id"], cli: cli, versioned: true).open!
    rows = JSON.parse(File.read(ENV["FAKE_TEMPER_CONTEXT"]))["rows"]
    assert_equal 1, rows.count { |row| row.dig("open_meta", "giraffe_run_id") == id }
  end

  def test_load_recovers_state_from_the_journal
    run = start
    recovered = Giraffe::Run.load(run.path)
    assert_equal run.id, recovered.id
    assert_equal run.state, recovered.state
  end

  def cli(*arguments)
    raw = @command.run!([RbConfig.ruby, File.join(ROOT, "bin/giraffe"), *arguments], cwd: @tmp, timeout: 120)
    JSON.parse(raw)
  end

  def test_cli_start_answer_and_resume_keep_script_position_and_human_answers
    source = {"triage" => [{"questions" => ["Which greeting?"]}, triage], "investigate" => [{"questions" => ["Where is the prior art?"]}]}
    script_file = File.join(@tmp, "script.json")
    ticket_file = File.join(@tmp, "ticket.json")
    config_file = File.join(@tmp, "giraffe.json")
    File.write(script_file, JSON.generate(source))
    File.write(ticket_file, JSON.generate(ticket))
    File.write(config_file, JSON.generate(config.data.merge("script" => script_file)))
    started = cli("start", "--ticket-file", ticket_file, "--config", config_file)
    assert_equal "waiting_for_answers", started["status"]
    question = started["questions"].first["id"]
    cli("answer", started["path"], question, "Use fixed")
    resumed = cli("resume", started["path"])
    assert_equal "waiting_for_answers", resumed["status"]
    assert_equal "investigate", resumed["questions"].first["role"]
    stored = Giraffe::Run.load(started["path"])
    assert_equal "Use fixed", stored.state["answers"][question]["answer"]
    assert_equal 2, stored.state.dig("runtime", "script_positions", "triage")
    assert_equal "waiting_for_answers", cli("graph", started["path"])["nodes"].find { |row| row["id"] == "INVESTIGATE" }["status"]
  end

  def test_cli_restore_installs_the_last_checkpoint_as_a_loadable_run
    run = start(store: "mirrored")
    assert run.sync["synced"]
    restored = cli("restore", run.id, "--context", "+test/runs", "--ticket", ticket["id"], "--destination", File.join(@tmp, "restored"))
    assert_equal "restored", restored["status"]
    assert_equal run.state["revision"], restored["revision"]
    assert_equal run.id, cli("status", restored["path"]).dig("graph", "run_id")
  end

  def test_cli_cancel_requests_an_active_run_and_marks_an_idle_one
    run = start
    active = run.lock { cli("cancel", run.path) }
    assert active["cancel_requested"]
    refute_equal "cancelled", active["status"], "the active harness stops itself"
    assert_equal "cancelled", cli("cancel", run.path)["status"]
  end

  def test_cli_dry_run_performs_no_run_model_temper_or_git_writes
    ticket_file = File.join(@tmp, "ticket.json")
    config_file = File.join(@tmp, "giraffe.json")
    File.write(ticket_file, JSON.generate(ticket))
    File.write(config_file, JSON.generate(config(store: "mirrored").data))
    head = @git.head(@repo)
    output = cli("start", "--ticket-file", ticket_file, "--config", config_file, "--dry-run")
    assert_equal "dry_run", output["status"]
    refute File.exist?(File.join(@tmp, "runs"))
    refute File.exist?(ENV["FAKE_TEMPER_LOG"])
    assert_equal head, @git.head(@repo)
  end

end
