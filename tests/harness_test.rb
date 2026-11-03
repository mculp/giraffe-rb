# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "socket"
require "etc"
require_relative "../lib/giraffe/harness"
require_relative "../lib/giraffe/graph_view"
require_relative "fixtures/screens/fit_check"

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

  # Passes or fails each run in its queue, and remembers which checkout each ran in.
  class ScriptedChecks
    attr_reader :runs
    def initialize(*exits) = (@exits, @runs = exits, [])
    def run(tree, commands)
      @runs << [tree, File.read(File.join(tree, "app.rb")), commands.first]
      [{"command" => commands.first, "exit_code" => @exits.shift, "excerpt" => "ran"}]
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
      "spec_command" => [RbConfig.ruby, "{spec}"], "runner" => "scripted").merge(overrides.transform_keys(&:to_s)))
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
     "audit" => [{"questions" => [], "clauses" => clauses.map { |id| {"clause_id" => id, "verdict" => "met", "evidence" => [{"ref" => "app.rb:1", "note" => "Executed checks pass"}]} }, "missed" => [], "screens" => []}],
     "pr_body" => [{"questions" => [], "title" => "Show requested greeting", "body" => "## Description\nChanges greeting.\n\n## Notes\nExecutable checks passed."}]}
  end

  # The run's copy in Temper, read the way a restore reads it.
  def remote_of(run)
    backend = Giraffe::Backends.build({"context" => "+test/runs"}, run_id: run.id, ticket: ticket["id"])
    PrGraph::Store.new(backend: backend, run_id: run.id)
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
    remote = remote_of(run)
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
    assert_equal 0.12, spent(run), "an invalid result still costs what it reported"
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
    assert_match(/spec_command/, assert_raises(Giraffe::Error) { config(spec_command: []) }.message)
    assert_match(/naming \{spec\}/, assert_raises(Giraffe::Error) { config(spec_command: ["rspec"]) }.message)
    assert_match(/naming \{spec\}/, assert_raises(Giraffe::Error) { config(spec_command: ["{spec}", 1]) }.message)
    assert_match(/--flag=\{line\}/, assert_raises(Giraffe::Error) { config(spec_command: ["rspec", "{spec}", "--line", "{line}"]) }.message)
    assert_match(/screen_checks/, assert_raises(Giraffe::Error) { config(screen_checks: "npm run horde") }.message)
  end

  def test_backends_build_temper_from_a_configuration_that_names_it_or_none
    [{}, {"backend" => "temper"}].each do |named|
      backend = Giraffe::Backends.build(named.merge("context" => "+test/runs"), run_id: SecureRandom.uuid, ticket: ticket["id"])
      assert_instance_of Giraffe::Backends::Temper, backend
      assert_equal "+test/runs", backend.to_s
      refute backend.holds_run?
      backend.open!
      assert backend.holds_run?
    end
    error = assert_raises(Giraffe::Error) { Giraffe::Backends.build({"backend" => "sqlite"}, run_id: SecureRandom.uuid, ticket: ticket["id"]) }
    assert_match(/unknown backend sqlite/, error.message)
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
    remote = remote_of(run)
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
    remote = remote_of(run)
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
    remote = remote_of(run)
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

  MUTATION = "diff --git a/app.rb b/app.rb\n--- a/app.rb\n+++ b/app.rb\n@@ -1 +1 @@\n-def greeting(name); \"Hello \" + name; end\n+def greeting(name); \"hello \" + name; end\n"

  # A reported defect in app.rb, with a script that reproduces it, fixes it and audits its regression spec.
  def bug_script
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
      "classes" => [], "patch" => MUTATION}]}]
    data
  end

  def start_bug(**overrides) = start(**{checks: [[RbConfig.ruby, "test/greeting_test.rb"]], spec_command: [RbConfig.ruby, "{spec}"]}, **overrides)
  def new_file_patch(path) = "diff --git a/#{path} b/#{path}\nnew file mode 100644\n--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1 @@\n+abort 'boom'\n"
  def copy(value) = Marshal.load(Marshal.dump(value))
  def refusal_in(call) = JSON.parse(call[:prompt].lines.last)["previous_output_refused_because"]
  def verification_of(run)
    record = run.coordinator.snapshot["artifacts"].find { |row| row["family"] == "verification" && row["status"] == "current" }
    JSON.parse(File.read(File.join(run.directory, record["content_ref"])))
  end

  # A refused output pauses the run, stays billed and is not replayed: resuming asks again and says why.
  def assert_resume_asks_again(role, data, refused, reason, **overrides)
    data[role] = [{"output" => refused, "cost_usd" => 0.25}, data.fetch(role).first]
    runner = Giraffe::Runners::Scripted.new(data)
    run = data.key?("reproduce") ? start_bug(**overrides) : start(**overrides)
    error = assert_raises(Giraffe::InvalidOutput, PrGraph::ContractError) { execute(run, runner) }
    assert_match(reason, error.message)
    assert_equal "paused", run.state["status"]
    assert_equal 0.25, spent(run)
    execute(run, runner)
    assert_equal "draft_pr", run.state["status"]
    asked = runner.calls.select { |call| call[:step] == role }
    assert_equal 2, asked.length
    assert_nil refusal_in(asked.first)
    assert_equal error.message, refusal_in(asked.last)
    run
  end

  def assert_mutation_refused(patch, reason = /existing production source only/)
    data = bug_script
    refused = copy(data["spec_audit"][0])
    refused["specs"][0]["patch"] = patch
    assert_resume_asks_again("spec_audit", data, refused, reason)
  end

  # Each refused output pauses the run and the next resume asks again, until the good one is accepted.
  def assert_refused_in_turn(role, data, refusals)
    good = data.fetch(role).first
    data[role] = refusals.map { |output, _reason| {"output" => output, "cost_usd" => 0.25} } << good
    runner = Giraffe::Runners::Scripted.new(data)
    run = start_bug
    refusals.each do |_output, reason|
      assert_match(reason, assert_raises(Giraffe::InvalidOutput) { execute(run, runner) }.message)
    end
    execute(run, runner)
    assert_equal "draft_pr", run.state["status"]
  end

  def test_regression_spec_that_cannot_be_a_file_the_candidate_commits_is_refused
    FileUtils.mkdir_p(File.join(@repo, "lib"))
    File.write(File.join(@repo, "lib/x.rb"), "X = 1\n")
    File.write(File.join(@repo, ".gitignore"), "generated/\n")
    data = bug_script
    reproduce = data["reproduce"][0]
    assert_refused_in_turn("reproduce", data, [
      [reproduce.merge("regression_spec" => "test/greeting_test.rb:1"), /must be a file path/],
      [reproduce.merge("regression_spec" => "test/a b_test.rb"), /must be a file path/],
      [reproduce.merge("regression_spec" => "test/"), /must be a file path/],
      [reproduce.merge("regression_spec" => "lib"), /not a directory/],
      [reproduce.merge("regression_spec" => "../outside_test.rb"), /invalid relative proof path/],
      [reproduce.merge("regression_spec" => "generated/greeting_test.rb"), /gitignored/]
    ])
  end

  def test_spec_audit_must_cite_a_line_of_a_changed_spec
    data = bug_script
    citing = lambda do |ref|
      audit = copy(data["spec_audit"][0])
      audit["specs"][0]["ref"] = ref
      [audit, /real changed spec and line/]
    end
    assert_refused_in_turn("spec_audit", data, %w[test/greeting_test.rb:99 test/greeting_test.rb:0 app.rb:1].map(&citing))
  end

  def test_spec_command_for_a_line_and_for_a_whole_file
    {
      ["rspec", "{spec}:{line}"] => [["rspec", "a_spec.rb:3"], ["rspec", "a_spec.rb"]],
      ["run", "{spec}", "--line={line}"] => [["run", "a_spec.rb", "--line=3"], ["run", "a_spec.rb"]],
      ["run", "{spec}", "{line}"] => [["run", "a_spec.rb", "3"], ["run", "a_spec.rb"]],
      ["sh", "-c", "run {spec} # line {line}"] => [["sh", "-c", "run a_spec.rb # line 3"], ["sh", "-c", "run a_spec.rb # line "]]
    }.each do |command, (at_line, whole_file)|
      harness = Giraffe::Harness.new(start(spec_command: command), runner: Giraffe::Runners::Scripted.new({}), github: @github)
      assert_equal at_line, harness.spec_command("a_spec.rb:3")
      assert_equal whole_file, harness.spec_command("a_spec.rb")
    end
  end

  def test_refused_triage_is_asked_again_on_resume
    refused = triage
    refused["outcome_register"]["negative_face"][0]["id"] = clauses[0]
    assert_resume_asks_again("triage", script, refused, /duplicate id/)
  end

  def test_output_the_schema_refuses_is_asked_again_on_resume
    assert_resume_asks_again("triage", script, {"questions" => [], "summary" => "thin"}, /outcome_register is required/)
  end

  def test_output_carrying_a_secret_is_asked_again_on_resume
    leaky = triage
    leaky["summary"] = "Found token ghp_#{'a' * 36} in fixtures"
    assert_resume_asks_again("triage", script, leaky, /secret pattern/)
  end

  def test_probe_that_does_not_reproduce_is_asked_again_on_resume
    data = bug_script
    assert_resume_asks_again("reproduce", data, data["reproduce"][0].merge("expected_exit" => 7),
                             /could not reproduce.*expected exit 7.*got exit 1.*wrong greeting/)
  end

  def test_probe_cannot_touch_the_worktree
    data = bug_script
    data["reproduce"][0]["source"] = 'File.write("scratch.txt", "x"); ' + data["reproduce"][0]["source"]
    run = start_bug
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    refute File.exist?(File.join(run.directory, "worktree", "scratch.txt"))
  end

  def test_refused_repro_report_is_asked_again_on_resume
    data = bug_script
    assert_resume_asks_again("reproduce", data, data["reproduce"][0].merge("clause_ids" => ["outcome:unknown"]), /unknown outcome clause/)
  end

  def test_plan_the_repro_contract_refuses_is_not_saved_and_is_asked_again_on_resume
    data = bug_script
    refused = copy(data["plan"][0])
    refused["implementation_plan"]["steps"][0]["evidence"].reject! { |item| item["kind"] == "reproduction" }
    run = assert_resume_asks_again("plan", data, refused, /must cite the repro_report/)
    plans = run.coordinator.snapshot["artifacts"].select { |row| row["family"] == "implementation_plan" }
    assert_equal 1, plans.length, "only the accepted plan is saved"
    assert_equal "current", plans.first["status"]
  end

  def test_plan_the_outcome_contract_refuses_is_asked_again_on_resume
    data = script
    refused = copy(data["plan"][0])
    refused["test_plan"]["coverage"].pop
    assert_resume_asks_again("plan", data, refused, /constraint:input/)
  end

  def test_audit_that_skips_a_clause_is_asked_again_on_resume
    data = script
    refused = copy(data["audit"][0])
    refused["clauses"].pop
    assert_resume_asks_again("audit", data, refused, /no verdict for clause/)
  end

  def test_spec_audit_that_skips_a_changed_spec_is_asked_again_on_resume
    data = bug_script
    data["build"][0]["writes"]["test/other_test.rb"] = data["build"][0]["writes"]["test/greeting_test.rb"]
    refused = copy(data["spec_audit"][0])
    data["spec_audit"][0]["specs"] << refused["specs"][0].merge("ref" => "test/other_test.rb:1")
    assert_resume_asks_again("spec_audit", data, refused, /no entry for changed spec/)
  end

  def test_mutation_patch_that_does_not_apply_is_asked_again_on_resume
    assert_mutation_refused(MUTATION.sub("Hello", "Howdy"), /does not apply/)
  end

  def test_mutation_that_changes_nothing_is_asked_again_on_resume
    assert_mutation_refused(MUTATION.sub("hello", "Hello"), /changed nothing/)
  end

  def test_mutation_cannot_add_a_gitignored_source_file
    File.write(File.join(@repo, ".gitignore"), "generated/\n")
    assert_mutation_refused(MUTATION + new_file_patch("generated/boom.rb"))
  end

  def test_mutation_cannot_change_an_existing_spec
    line = 'require_relative "../app"; abort "wrong greeting" unless greeting("Ada") == "Hello Ada"'
    assert_mutation_refused("diff --git a/test/greeting_test.rb b/test/greeting_test.rb\n--- a/test/greeting_test.rb\n+++ b/test/greeting_test.rb\n@@ -1 +1 @@\n-#{line}\n+abort 'boom'\n")
  end

  def test_mutation_cannot_rename_a_spec_onto_production_source
    source = 'def greeting(name); "Hello " + name; end'
    assert_mutation_refused("diff --git a/app.rb b/app.rb\ndeleted file mode 100644\n--- a/app.rb\n+++ /dev/null\n@@ -1 +0,0 @@\n-#{source}\n" \
                            "diff --git a/test/greeting_test.rb b/app.rb\nsimilarity index 100%\nrename from test/greeting_test.rb\nrename to app.rb\n")
  end

  def test_only_production_source_can_be_mutated
    %w[app.rb lib/a/b.rb src/x.ts pkg/main.go src/Main.java lib/latest.py app/models/lab_test.rb src/ABTest.java src/app.config.ts
       app/views/a.erb src/App.vue src/Contest.java lib/tasks/a.rake app/views/a.html.haml app/views/a.slim src/a.mjs src/a.cts src/A.svelte
       src/A.kt src/A.swift src/a.php lib/a.heex app/views/api/w.json.jbuilder app/views/a.rabl app/views/a.xml.builder src/app/a.component.html
       views/a.ejs views/a.hbs views/a.liquid scripts/deploy.sh].each do |path|
      assert PrGraph::SpecAuditContract.production_source?(path), "#{path} is production source"
    end
    %w[.hidden.rb lib/.hidden.rb notes.txt Gemfile spec/a_spec.rb test/a_test.rb src/a.spec.ts test/support/boom.rb tests/conftest.py
       conftest.py spec_helper.rb test_helper.rb __tests__/x.js config/environments/test.rb jest.config.js pkg/x_test.go lib/x_test.py
       test_x.py src/FooTest.java web/jest.config.js packages/a/vitest.config.ts jest.config.ts vite.config.ts src/foo_test.ts lib/foo_spec.rb
       Tests/AppTests/FooTests.swift Tests/AppTests/Helpers.swift src/x.test.mjs src/FooTests.java config/locales/en.yml bin/tool app/assets/a.scss].each do |path|
      refute PrGraph::SpecAuditContract.production_source?(path), "#{path} is not production source"
    end
  end

  def mutation_runner(checks, **options) = Giraffe::MutationRunner.new(git: @git, checks: checks, worktree: @repo, candidate: @git.head(@repo), **options)

  def app_patch(line) = "diff --git a/app.rb b/app.rb\n--- a/app.rb\n+++ b/app.rb\n@@ -1 +1 @@\n-puts 'base'\n+#{line}\n"

  def test_mutation_runner_runs_a_command_unmutated_once_and_each_mutation_in_its_own_checkout
    checks = ScriptedChecks.new(0, 1, 1, 0, 1)
    runner = mutation_runner(checks)
    assert_equal 1, runner.prove(app_patch("puts 'one'"), ["spec-a"])["exit_code"]
    assert_equal 1, runner.prove(app_patch("puts 'two'"), ["spec-a"])["exit_code"]
    assert_equal 1, runner.prove(app_patch("puts 'three'"), ["spec-b"])["exit_code"]
    trees, sources, commands = checks.runs.transpose
    assert_equal [["spec-a"], ["spec-a"], ["spec-a"], ["spec-b"], ["spec-b"]], commands
    assert_equal ["puts 'base'\n", "puts 'one'\n", "puts 'two'\n", "puts 'base'\n", "puts 'three'\n"], sources
    assert_equal trees.uniq, trees, "a mutation never runs where an earlier run left anything behind"
  end

  def test_mutation_runner_blames_the_candidate_when_a_spec_fails_unmutated
    checks = ScriptedChecks.new(1)
    error = assert_raises(Giraffe::BaselineFailed) { mutation_runner(checks).prove(app_patch("puts 'one'"), ["spec-a"]) }
    assert_match(/spec-a fails from a clean checkout.*ran/, error.message)
    assert_equal 1, checks.runs.length, "a failing baseline never runs the mutation"
  end

  def test_mutation_runner_asks_the_injected_policy_what_counts_as_production
    checks = ScriptedChecks.new(0)
    runner = mutation_runner(checks, production: ->(_path) { false })
    error = assert_raises(Giraffe::InvalidOutput) { runner.prove(app_patch("puts 'one'"), ["spec-a"]) }
    assert_match(/existing production source only: app\.rb/, error.message)
    assert_equal ["puts 'base'\n"], checks.runs.map { |_tree, source, _command| source }, "a refused patch never runs"
  end

  def test_mutation_runner_refuses_a_new_file_before_running_anything
    checks = ScriptedChecks.new
    error = assert_raises(Giraffe::InvalidOutput) { mutation_runner(checks).prove(new_file_patch("lib/new.rb"), ["spec-a"]) }
    assert_match(/existing production source only: lib\/new\.rb/, error.message)
    assert_empty checks.runs
  end

  def test_ignored_files_a_checkout_hook_provides_stay_available_to_specs
    File.write(File.join(@repo, ".gitignore"), "generated/\n")
    hook = File.join(@repo, ".git/hooks/post-checkout")
    File.write(hook, "#!/bin/sh\nmkdir -p generated && echo > generated/helper.rb\n")
    File.chmod(0o755, hook)
    data = bug_script
    data["build"][0]["writes"]["test/greeting_test.rb"] = %(require_relative "../generated/helper"; #{data['build'][0]['writes']['test/greeting_test.rb']})
    run = start_bug
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 1, run.coordinator.snapshot["attempts"].values.count { |attempt| attempt["node"] == "BUILD" }
  end

  def test_mutation_that_hangs_counts_as_caught
    data = bug_script
    data["spec_audit"][0]["specs"][0]["patch"] = MUTATION.sub('"hello " + name', "sleep 30")
    run = start_bug(check_timeout: 2)
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 124, verification_of(run).dig("mutation_proofs", 0, "exit_code")
  end

  def test_check_past_its_limits_is_a_failed_check
    checks = Giraffe::Checks.new(config(check_timeout: 1), command: @command)
    slow, noisy = checks.run(@tmp, [[RbConfig.ruby, "-e", "sleep 30"], [RbConfig.ruby, "-e", 'print "x" * 3_000_000']])
    assert_equal [124, 124], [slow["exit_code"], noisy["exit_code"]]
    assert_match(/timed out/, slow["excerpt"])
    assert_match(/exceeds/, noisy["excerpt"])
  end

  def test_check_output_never_carries_a_token
    checks = Giraffe::Checks.new(config, command: @command)
    result = checks.run(@tmp, [[RbConfig.ruby, "-e", %(puts "before ghp_" + "a" * 36 + " after")]]).first
    assert_equal "before [REDACTED] after\n", result["excerpt"]
  end

  def test_cutting_check_output_cannot_leave_part_of_a_token
    checks = Giraffe::Checks.new(config, command: @command)
    result = checks.run(@tmp, [[RbConfig.ruby, "-e", %(print "ghp_" + "a" * 36 + "." * 11_990)]]).first
    assert_equal "[REDACTED]#{'.' * 11_990}", result["excerpt"]
    result = checks.run(@tmp, [[RbConfig.ruby, "-e", %(print "." * 20_000 + "end")]]).first
    assert_equal "#{'.' * 11_997}end", result["excerpt"]
  end

  def test_one_of_reports_what_each_shape_lacks_and_refuses_an_output_fitting_both
    either = {"oneOf" => [{"type" => "object", "required" => ["a"]}, {"type" => "object", "required" => ["b"]}]}
    assert_empty Giraffe::Schema.errors(either, {"a" => 1})
    assert_equal ["$ must match exactly one of: $.a is required OR $.b is required"], Giraffe::Schema.errors(either, {})
    assert_equal ["$ must match exactly one of: matched OR matched"], Giraffe::Schema.errors(either, {"a" => 1, "b" => 1})
    long = {"oneOf" => [{"type" => "object", "required" => ("a".."z").to_a}, {"type" => "array"}]}
    assert_equal 8, Giraffe::Schema.errors(long, {}).first.scan("is required").length, "a refusal stays short enough to store"
  end

  def test_runner_reporting_an_impossible_cost_keeps_its_reservation
    data = script
    data["triage"] = [{"output" => triage, "cost_usd" => -1.0}]
    run = start
    assert_match(/invalid cost/, assert_raises(Giraffe::InvalidOutput) { execute(run, data) }.message)
    assert_equal run.config["call_budget_usd"], spent(run)
  end

  def test_failed_call_bills_what_it_reported
    failure = Giraffe::Error.new("runner failed")
    failure.usage = {"cost_usd" => 0.5, "turns" => 1}
    data = script
    data["triage"] = [failure]
    run = start
    assert_raises(Giraffe::Error) { execute(run, data) }
    assert_equal [0.5, "failed"], Giraffe::CallLedger.new(run).entries.values.first.values_at("charge", "state")
  end

  def test_run_budget_limits_later_calls_and_stops_once_spent
    thin = {"questions" => [], "summary" => "thin"}
    data = script
    data["triage"] = [{"output" => thin, "cost_usd" => 0.25}, {"output" => thin, "cost_usd" => 0.05}, triage]
    runner = Giraffe::Runners::Scripted.new(data)
    run = start(run_budget_usd: 0.3005)
    2.times { assert_raises(Giraffe::InvalidOutput) { execute(run, runner) } }
    assert_in_delta 0.0505, runner.calls.last[:budget_usd], 0.0001
    assert_match(/budget exhausted/, assert_raises(Giraffe::Error) { execute(run, runner) }.message)
    assert_equal 2, runner.calls.length
  end

  def test_whitespace_only_regression_output_still_records_the_run
    data = bug_script
    data["build"][0]["writes"]["test/greeting_test.rb"] = %(require_relative "../app"; (puts "  "; exit 1) unless greeting("Ada") == "Hello Ada"\n)
    run = start_bug
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal "exit 1", verification_of(run).dig("regression", "base", "excerpt")
  end

  def test_regression_candidate_side_runs_from_a_clean_checkout
    File.write(File.join(@repo, ".gitignore"), "generated/\n")
    data = bug_script
    spec = data["build"][0]["writes"].delete("test/greeting_test.rb")
    data["reproduce"][0]["regression_spec"] = "checks/greeting_check.rb"
    data["build"][0]["writes"]["checks/greeting_check.rb"] = %(require_relative "../generated/helper"; #{spec})
    data["build"] << {"output" => {"questions" => [], "summary" => "Made the check self-contained"}, "writes" => {"checks/greeting_check.rb" => spec}}
    data["review"] << data["review"][0]
    data["audit"] << data["audit"][0]
    data.delete("spec_audit")
    prepare = "require 'fileutils'; FileUtils.mkdir_p('generated'); File.write('generated/helper.rb', ''); load 'checks/greeting_check.rb'"
    run = start(checks: [[RbConfig.ruby, "-e", prepare]], spec_command: [RbConfig.ruby, "{spec}"])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 2, run.coordinator.snapshot["attempts"].values.count { |attempt| attempt["node"] == "BUILD" }
  end

  def test_spec_needing_ignored_state_goes_red_instead_of_faking_a_kill
    File.write(File.join(@repo, ".gitignore"), "generated/\n")
    data = bug_script
    spec = data["build"][0]["writes"]["test/greeting_test.rb"]
    data["build"][0]["writes"]["test/greeting_test.rb"] = %(require_relative "../generated/helper"; #{spec})
    data["build"] << {"output" => {"questions" => [], "summary" => "Made the spec self-contained"}, "writes" => {"test/greeting_test.rb" => spec}}
    data["review"] << data["review"][0]
    data["audit"] << data["audit"][0]
    data["spec_audit"] << data["spec_audit"][0]
    prepare = "require 'fileutils'; FileUtils.mkdir_p('generated'); File.write('generated/helper.rb', ''); load 'test/greeting_test.rb'"
    run = start(checks: [[RbConfig.ruby, "-e", prepare]], spec_command: [RbConfig.ruby, "{spec}"])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 2, run.coordinator.snapshot["attempts"].values.count { |attempt| attempt["node"] == "BUILD" }
    assert_includes @runner.calls.select { |call| call[:step] == "build" }.last[:prompt], "clean checkout"
  end

  def unverifiable_audit(data)
    copy(data["audit"][0]).tap do |audit|
      audit["clauses"][0] = {"clause_id" => clauses[0], "verdict" => "unverifiable", "reason" => "Cannot tell from here"}
    end
  end

  def test_red_that_build_has_no_edit_for_asks_a_person_and_the_audit_hears_the_answer
    data = script
    data["audit"] = [unverifiable_audit(data), data["audit"][0]]
    data["review"] *= 2
    data["build"] << {"output" => {"questions" => [], "summary" => "Nothing to change"}}
    runner = Giraffe::Runners::Scripted.new(data)
    run = start
    execute(run, runner)
    assert_equal "waiting_for_answers", run.state["status"]
    question = run.state["questions"].first
    assert_includes question["text"], "Cannot tell from here"
    assert_includes question["text"], run.coordinator.snapshot["artifacts"].find { |row| row["family"] == "verification" }["candidate_sha"]
    assert_equal 1, runner.calls.count { |call| call[:step] == "audit" }
    run.answer(question["id"], "The browser suite passed on this candidate")
    execute(run, runner)
    assert_equal "draft_pr", run.state["status"]
    assert_includes runner.calls.select { |call| call[:step] == "audit" }.last[:prompt], "browser suite passed"
  end

  def test_red_build_asked_about_itself_is_not_asked_again_once_answered
    data = script
    data["audit"] = [unverifiable_audit(data), data["audit"][0]]
    data["review"] *= 2
    data["build"] += [{"output" => {"questions" => ["Can someone run the browser suite?"]}}, {"output" => {"questions" => [], "summary" => "Nothing to change"}}]
    runner = Giraffe::Runners::Scripted.new(data)
    run = start
    execute(run, runner)
    question = run.state["questions"].first
    assert_equal "Can someone run the browser suite?", question["text"]
    run.answer(question["id"], "It passed on this candidate")
    execute(run, runner)
    assert_equal "draft_pr", run.state["status"]
  end

  def test_red_an_answer_does_not_settle_reaches_the_recurrence_stop
    data = script
    data["audit"] = [unverifiable_audit(data)] * 6
    data["review"] *= 6
    data["build"] += Array.new(5) { {"output" => {"questions" => [], "summary" => "Nothing to change"}} }
    runner = Giraffe::Runners::Scripted.new(data)
    run = start
    3.times do
      execute(run, runner)
      run.answer(run.state["questions"].first["id"], "I cannot tell either")
    end
    error = assert_raises(PrGraph::Coordinator::CoordinatorError) { execute(run, runner) }
    assert_match(/recurring failure.*verification.*remain unverifiable/, error.message)
    assert_equal "paused", run.state["status"]
    assert run.coordinator.snapshot.dig("failure_queue", "stopped")
    assert_empty @github.calls
  end

  # A screen check that draws the named pictures, the way a browser suite's --shots does.
  def draws(*names)
    [RbConfig.ruby, "-e", "%w[#{names.join(' ')}].each { |name| File.binwrite(File.join(ARGV[0], name), 'picture of ' + name) }", "{shots}"]
  end

  def ruled(*rows) = copy(script["audit"][0]).merge("screens" => rows)
  def looks_fine(name) = {"name" => name, "verdict" => "fits", "note" => "All of it is on the screen"}
  def looks_broken(name, note) = {"name" => name, "verdict" => "broken", "note" => note}
  def calls_to(role) = @runner.calls.select { |call| call[:step] == role }
  def edit(summary, content) = {"output" => {"questions" => [], "summary" => summary}, "writes" => {"app.rb" => content}}

  # The cut-down HUD of the first version of CHUNKY-22, in real Chrome through the real macOS sandbox. Every gate
  # passed it. A person found it in a screenshot, and its fix, 81d2a72, measures what this fixture does.
  def test_the_line_that_ran_off_a_phone_at_695756d_cannot_reach_a_draft
    skip "no Chrome here to draw with" unless ScreenFit.chrome
    fixture = ->(name) { File.read(File.join(ROOT, "tests/fixtures/screens", name), encoding: "UTF-8") }
    data = script
    data["build"][0]["writes"].merge!("hud.html" => fixture["hud_695756d.html"], "fit_check.rb" => fixture["fit_check.rb"])
    data["build"] << {"output" => {"questions" => [], "summary" => "Two short rows"}, "writes" => {"hud.html" => fixture["hud_81d2a72.html"]}}
    data["review"] *= 2
    data["audit"] = [ruled(looks_fine("hud-320.png"), looks_fine("hud-390.png"))]
    check = [RbConfig.ruby, "fit_check.rb", "hud.html", "{shots}"]
    run = start(screen_checks: [check], sandbox_checks: RbConfig::CONFIG["host_os"].include?("darwin"))
    execute(run, data)
    verifications = run.coordinator.snapshot["artifacts"].select { |row| row["family"] == "verification" }
    stopped = JSON.parse(File.read(File.join(run.directory, verifications.first["content_ref"])))
    assert_equal 1, stopped["failures"]
    assert_equal 1, stopped["checks"].last["exit_code"]
    assert_match(/FAIL at 320 wide: "Hood up .* 100%" ends at \d+/, stopped["checks"].last["excerpt"])
    assert_match(/FAIL at 320 wide/, calls_to("build").last[:prompt], "BUILD hears where the line ended")
    assert_equal 1, calls_to("audit").length, "nothing is paid to audit a screen that does not fit"
    assert_equal "draft_pr", run.state["status"]
    refute_equal stopped["candidate_sha"], run.coordinator.snapshot["published"]["candidate_sha"]
    assert_equal %w[hud-320.png hud-390.png], verification_of(run)["screenshots"].map { |shot| shot["name"] }
    assert_equal "\x89PNG".b, File.binread(verification_of(run)["screenshots"].first["path"], 4), "they are real pictures"
  end

  def test_a_failing_screen_check_goes_red_before_an_audit_is_paid_for
    data = script
    data["build"] << edit("Made it fit", "puts 'fixed again'\n")
    data["review"] *= 2
    fits_once_fixed = [RbConfig.ruby, "-e", "abort 'it ends at 467 of 390' unless File.read('app.rb').include?('again')"]
    run = start(screen_checks: [fits_once_fixed])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 1, calls_to("audit").length
    assert_includes calls_to("build").last[:prompt], "it ends at 467 of 390"
    assert_equal 1, @github.calls.length
  end

  def test_what_a_screen_check_draws_is_kept_and_the_auditor_must_rule_on_each_picture
    data = script
    data["audit"] = [ruled(looks_fine("a.png"), looks_fine("b.png"))]
    run = assert_resume_asks_again("audit", data, ruled(looks_fine("a.png")), /b\.png/, screen_checks: [draws("a.png", "b.png")], store: "mirrored")
    shots = verification_of(run)["screenshots"]
    assert_equal %w[a.png b.png], shots.map { |shot| shot["name"] }
    assert_equal "picture of b.png", File.read(shots.last["path"])
    assert_equal Digest::SHA256.hexdigest("picture of b.png"), shots.last["sha256"]
    assert_includes calls_to("audit").last[:prompt], shots.last["path"]
    assert_includes calls_to("plan").first[:prompt], "{shots}", "PLAN knows what will look at the screen"
    assert_equal "{shots}", verification_of(run)["checks"].last["command"].last, "recorded as declared, not with a directory that is gone"
    assert_empty @git.call(File.join(run.directory, "worktree"), "status", "--porcelain"), "they drew in a checkout of their own"
    assert_equal [%w[a.png fits], %w[b.png fits]], verification_of(run)["screens"].map { |row| row.values_at("name", "verdict") }
    assert_includes File.read(ENV["FAKE_TEMPER_CONTEXT"]), shots.last["sha256"], "the store knows which picture was ruled on"
    refute_includes File.read(ENV["FAKE_TEMPER_CONTEXT"]), "picture of b.png", "but the picture stays on this host"
  end

  def test_a_link_a_candidate_planted_is_not_kept_as_a_picture
    private_file = File.join(@tmp, "private.png")
    File.write(private_file, "not for anyone")
    plants = [RbConfig.ruby, "-e", "File.symlink(#{private_file.inspect}, File.join(ARGV[0], 'planted.png')); File.write(File.join(ARGV[0], 'real.png'), 'pixels')", "{shots}"]
    data = script
    data["audit"] = [ruled(looks_fine("real.png"))]
    run = start(screen_checks: [plants])
    execute(run, data)
    assert_equal %w[real.png], verification_of(run)["screenshots"].map { |shot| shot["name"] }
  end

  def test_a_screen_ruled_broken_stops_the_draft_and_asks_a_person_to_look_at_that_picture
    data = script
    data["audit"] = [ruled(looks_broken("hood.png", "The line runs off the right edge")), ruled(looks_fine("hood.png"))]
    data["review"] *= 2
    data["build"] << {"output" => {"questions" => [], "summary" => "Nothing to change"}}
    runner = Giraffe::Runners::Scripted.new(data)
    run = start(screen_checks: [draws("hood.png")])
    execute(run, runner)
    assert_equal "waiting_for_answers", run.state["status"]
    assert_empty @github.calls
    picture = verification_of(run)["screenshots"].first["path"]
    assert_includes calls_to("build").last[:prompt], "The line runs off the right edge"
    assert_includes calls_to("build").last[:prompt], picture
    question = run.state["questions"].first
    assert_includes question["text"], "The line runs off the right edge"
    assert_includes question["text"], picture
    run.answer(question["id"], "That is a known leftover, fine for this ticket")
    execute(run, runner)
    assert_equal "draft_pr", run.state["status"]
    assert_includes calls_to("audit").last[:prompt], "known leftover"
  end

  def test_a_ui_ticket_whose_screen_checks_drew_nothing_goes_red
    data = script
    data["plan"][0]["ui"] = true
    data["build"] << edit("Took a screenshot of it", "puts 'fixed again'\n")
    data["review"] *= 2
    data["audit"] = [ruled(looks_fine("a.png"))]
    draws_once_fixed = [RbConfig.ruby, "-e", "File.write(File.join(ARGV[0], 'a.png'), 'pixels') if File.read('app.rb').include?('again')", "{shots}"]
    run = start(screen_checks: [draws_once_fixed])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 2, run.coordinator.snapshot["attempts"].values.count { |attempt| attempt["node"] == "BUILD" }
    assert_match(/no screenshot/, calls_to("build").last[:prompt])
    assert_equal 1, calls_to("audit").length
  end

  # Triage's flag alone: PLAN saying otherwise does not make the screen visible to anything.
  def test_a_ui_ticket_nothing_can_see_asks_a_person_to_look_at_each_candidate
    data = script
    data["triage"][0]["ui"] = true
    broken = copy(data["audit"][0])
    broken["clauses"][0] = {"clause_id" => clauses[0], "verdict" => "unmet", "reason" => "A person saw it run off the screen"}
    data["audit"] = [broken, data["audit"][0]]
    data["build"] << edit("Made it fit", "puts 'fixed again'\n")
    data["review"] *= 2
    runner = Giraffe::Runners::Scripted.new(data)
    run = start
    execute(run, runner)
    assert_equal "waiting_for_answers", run.state["status"]
    assert_empty calls_to("audit"), "a person looks before an audit is paid for"
    first = run.state["questions"].first
    worktree = File.join(run.directory, "worktree")
    assert_includes first["text"], @git.head(worktree)
    run.answer(first["id"], "It runs off the right edge at 390 wide")
    execute(run, runner)
    assert_includes calls_to("audit").first[:prompt], "runs off the right edge"
    assert_equal "waiting_for_answers", run.state["status"]
    second = run.state["questions"].first
    assert_includes second["text"], @git.head(worktree), "what was seen on one candidate says nothing about the next"
    refute_equal first["id"], second["id"]
    run.answer(second["id"], "All of it is on the screen now")
    execute(run, runner)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 1, @github.calls.length
  end

  # With the network open, what a screen check can read can leave.
  def test_a_screen_check_gets_the_network_and_little_of_the_home_directory
    skip "the sandbox is macOS only" unless RbConfig::CONFIG["host_os"].include?("darwin")
    home = File.join(File.realpath(@tmp), "home")
    FileUtils.mkdir_p(%w[.ssh tool/bin tool/lib].map { |path| File.join(home, path) })
    {".ssh/id" => "private", "notes.txt" => "private", "tool/lib/runtime" => "a tool's own file", "tool/credentials.toml" => "private", ".gitconfig" => "[user]\n"}.each { |path, text| File.write(File.join(home, path), text) }
    ENV["HOME"] = home
    ENV["PATH"] = "#{File.join(home, 'tool/bin')}:#{ENV['PATH']}"
    server = TCPServer.new("127.0.0.1", 0)
    connects = [RbConfig.ruby, "-rsocket", "-e", "TCPSocket.new('127.0.0.1', #{server.addr[1]})"]
    reads = ->(path) { [RbConfig.ruby, "-e", "File.read(#{File.join(home, path).inspect})"] }
    outside = File.join(Etc.getpwuid.dir, ".giraffe-sandbox-probe-#{Process.pid}")
    writes_outside = [RbConfig.ruby, "-e", "File.write(#{outside.inspect}, 'x')"]
    checks = Giraffe::Checks.new(config(sandbox_checks: true), command: @command)
    plain = ->(command) { checks.run(@repo, [command]).first["exit_code"] }
    open = ->(command) { checks.run(@repo, [command], network: true).first["exit_code"] }

    refute_equal 0, plain[connects], "an ordinary check stays off the network"
    assert_equal 0, plain[reads["notes.txt"]], "and reads as it always has"
    refute_equal 0, plain[reads[".ssh/id"]]

    assert_equal 0, open[connects]
    refute_equal 0, open[reads["notes.txt"]]
    refute_equal 0, open[reads[".ssh/id"]]
    assert_equal 0, open[reads["tool/lib/runtime"]], "the libraries beside a tool on its PATH stay readable"
    refute_equal 0, open[reads["tool/credentials.toml"]], "and nothing else beside it does"
    assert_equal 0, open[reads[".gitconfig"]], "git dies without it"
    refute_equal 0, open[writes_outside]
    refute File.exist?(outside)
  ensure
    server&.close
    FileUtils.rm_f(outside) if outside
  end

  # A process asks the keychain's services for a token, so no file rule covers it. No password is read here: there is
  # no such item. A search the services refuse says it was not valid, and one they answer only that nothing was found.
  def test_no_check_can_reach_the_keychain
    skip "the sandbox is macOS only" unless RbConfig::CONFIG["host_os"].include?("darwin")
    asks = ["/usr/bin/security", "find-generic-password", "-s", "giraffe-test-no-such-item"]
    checks = Giraffe::Checks.new(config(sandbox_checks: true), command: @command)
    refute_match(/not valid/, @command.capture(asks, cwd: @repo)["stderr"], "outside the sandbox the keychain answers")
    assert_match(/not valid/, checks.run(@repo, [asks]).first["excerpt"])
    assert_match(/not valid/, checks.run(@repo, [asks], network: true).first["excerpt"])
  end

  def test_a_run_started_before_screen_checks_existed_still_runs
    old = Giraffe::Config.new(config.data.reject { |key, _| key == "screen_checks" }, resolved: true)
    run = Giraffe::Run.start(old, ticket)
    execute(run)
    assert_equal "draft_pr", run.state["status"]
  end

  def test_candidate_missing_its_regression_spec_goes_red_instead_of_stopping_the_run
    data = bug_script
    spec = data["build"][0]["writes"].delete("test/greeting_test.rb")
    data["build"][0]["writes"]["test/other_test.rb"] = spec
    data["build"] << {"output" => {"questions" => [], "summary" => "Added the regression spec"}, "writes" => {"test/greeting_test.rb" => spec}}
    data["review"] << data["review"][0]
    data["audit"] << data["audit"][0]
    other = copy(data["spec_audit"][0])
    other["specs"][0]["ref"] = "test/other_test.rb:1"
    both = copy(other)
    both["specs"] << data["spec_audit"][0]["specs"][0]
    data["spec_audit"] = [other, both]
    run = start(checks: [[RbConfig.ruby, "test/other_test.rb"]], spec_command: [RbConfig.ruby, "{spec}"])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 2, run.coordinator.snapshot["attempts"].values.count { |attempt| attempt["node"] == "BUILD" }
    fix = @runner.calls.select { |call| call[:step] == "build" }.last
    assert_includes fix[:prompt], "regression spec"
  end

  def test_bug_path_executes_reproduction_regression_and_real_mutation
    data = bug_script
    run = start_bug
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
    Giraffe::Backends.build({"context" => "+test/runs"}, run_id: id, ticket: ticket["id"], cli: cli, versioned: true).open!
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

  def spent(run) = Giraffe::CallLedger.new(run).spent
  def install_hook(body, name: "post-checkout")
    hook = File.join(@repo, ".git/hooks", name)
    File.write(hook, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, hook)
  end
  def commit_base(message)
    @git.commit(@repo, message)
    @git.call(@repo, "push", "origin", "main")
  end
  def app_mutation = "diff --git a/app.rb b/app.rb\n--- a/app.rb\n+++ b/app.rb\n@@ -1 +1 @@\n-puts 'fixed'\n+puts 'broken'\n"
  def pinning_spec = %(abort "wrong" unless File.read("app.rb").include?("fixed")\n)
  def audit_of(ref, patch = app_mutation) = {"questions" => [], "specs" => [{"ref" => ref, "behavior" => "Greets", "classes" => [], "patch" => patch}]}
  def start_with_spec(path = "test/x_test.rb", **overrides) = start(**{checks: [[RbConfig.ruby, path]], spec_command: [RbConfig.ruby, "{spec}"]}, **overrides)

  # One more BUILD, review and audit round for each entry, as the fix after a red VERIFY.
  def with_fix_rounds(data, count, writes = {})
    data["build"] += Array.new(count) { {"output" => {"questions" => [], "summary" => "Addressed the failure"}, "writes" => writes} }
    data["review"] *= count + 1
    data["audit"] *= count + 1
    data
  end

  def test_specs_are_recognised_by_each_languages_conventions
    %w[spec/x_spec.rb lib/foo_spec.rb engines/a/spec/x_spec.rb spec/x_test.rb test/x_test.rb tests/x_test.rb test/test_x.rb tests/nested/test_x.rb
       src/x.test.ts src/x.spec.mts src/x.test.mjs src/foo_test.ts __tests__/x.js cypress/e2e/x.cy.ts
       tests/test_x.py test_x.py tests/x_test.py pkg/x_test.go test/x_test.exs
       src/test/java/FooTest.java src/test/kotlin/FooTest.kt src/test/java/ABTest.java src/FooTests.java tests/XTest.php
       Tests/AppTests/FooTests.swift tests/x.rs].each do |path|
      assert PrGraph::SpecAuditContract.spec_path?(path), "#{path} is a spec"
    end
    %w[app.rb app/models/lab_test.rb lib/latest.py src/ABTest.java src/Contest.java tests/common/mod.rs test/support/boom.rb tests/conftest.py
       pharmacy.js].each do |path|
      refute PrGraph::SpecAuditContract.spec_path?(path), "#{path} is not a spec"
    end
  end

  def test_hook_failing_while_the_worktree_is_made_is_reported_and_the_worktree_made_again
    File.write(File.join(@repo, ".gitignore"), "generated/\n")
    commit_base("ignore generated")
    once = File.join(@tmp, "failed-once")
    install_hook("if [ ! -e #{once} ]; then touch #{once} stray.txt; echo 'could not fetch gems' >&2; exit 1; fi\nmkdir -p generated && echo > generated/helper.rb")
    data = script
    data["build"][0]["writes"]["test/x_test.rb"] = %(require_relative "../generated/helper"; #{pinning_spec})
    data["spec_audit"] = [audit_of("test/x_test.rb:1")]
    runner = Giraffe::Runners::Scripted.new(data)
    run = start_with_spec
    assert_match(/could not fetch gems/, assert_raises(Giraffe::Error) { execute(run, runner) }.message)
    execute(run, runner)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 1, runner.calls.count { |call| call[:step] == "build" }, "BUILD is not paid to work in a half-made checkout"
    refute File.exist?(File.join(run.directory, "worktree/stray.txt"))
  end

  def test_only_this_runs_own_unfinished_worktree_is_made_again
    path = File.join(@tmp, "tree")
    options = {repo: @repo, path: path, base: "origin/main"}
    @git.worktree(**options, branch: "run-a")
    @git.call(@repo, "worktree", "lock", path)
    assert_equal "run-a", @git.call(@git.worktree(**options, branch: "run-a")["path"], "branch", "--show-current")
    assert_match(/another branch/, assert_raises(Giraffe::Error) { @git.worktree(**options, branch: "run-b") }.message)
    assert File.directory?(path), "someone else's worktree stays"
    elsewhere = File.join(@tmp, "plain")
    Dir.mkdir(elsewhere)
    assert_raises(Giraffe::Error) { @git.worktree(**options, path: elsewhere, branch: "run-a") }
    inside = File.join(@repo, "inside")
    Dir.mkdir(inside)
    assert_match(/unexpected existing worktree/, assert_raises(Giraffe::Error) { @git.worktree(**options, path: inside, branch: "main") }.message)
    assert File.directory?(inside)
  end

  def test_another_repositorys_worktree_is_not_removed
    other = File.join(@tmp, "other")
    @command.run!(["git", "clone", "-q", @origin, other], cwd: @tmp)
    path = File.join(@tmp, "theirs")
    @git.call(other, "worktree", "add", "-b", "run-a", path, "origin/main")
    error = assert_raises(Giraffe::Error) { @git.worktree(repo: @repo, path: path, branch: "run-a", base: "origin/main") }
    assert_match(/another repository/, error.message)
    assert File.directory?(path)
  end

  def test_checkouts_give_a_hook_time_and_none_of_the_harness_credentials
    seen = File.join(@tmp, "hook-env.txt")
    install_hook("env >> #{seen}")
    ENV["ANTHROPIC_API_KEY"] = "controller-credential"
    command = Class.new(Giraffe::Command) do
      def timeouts = @timeouts ||= []
      def run!(argv, **options)
        timeouts << options[:timeout] if argv.include?("add")
        super
      end
    end.new
    git = Giraffe::Git.new(command: command)
    git.worktree(repo: @repo, path: File.join(@tmp, "tree"), branch: "run-a", base: "origin/main")
    git.at_commit(@repo, @git.head(@repo)) { |_tree| nil }
    assert_equal [600, 600], command.timeouts
    env = File.read(seen)
    refute_includes env, "ANTHROPIC_API_KEY"
    assert_includes env, "PATH="
  end

  def test_proof_checkout_whose_hook_fails_reports_it_and_leaves_nothing_registered
    install_hook("echo 'bundle install failed' >&2; exit 1")
    ran = false
    error = assert_raises(Giraffe::Error) { @git.at_commit(@repo, @git.head(@repo)) { |_tree| ran = true } }
    assert_match(/bundle install failed/, error.message)
    refute ran
    refute_includes @git.call(@repo, "worktree", "list"), "giraffe-proof-"
  end

  def test_proof_checkout_of_a_missing_commit_reports_that
    error = assert_raises(Giraffe::Error) { @git.at_commit(@repo, "0" * 40) { |_tree| flunk "there is nothing to check out" } }
    assert_match(/invalid reference/, error.message)
  end

  def test_tail_of_command_output_is_short_and_keeps_its_lines
    assert_equal "a\nb", Giraffe::Command.tail("  a\nb\n")
    assert_equal "x" * 999 + "z", Giraffe::Command.tail("y" * 5 + "x" * 999 + "z")
  end

  def test_read_only_directory_left_in_a_proof_checkout_does_not_stop_the_run
    leftover = nil
    @git.at_commit(@repo, @git.head(@repo)) do |tree|
      leftover = tree
      FileUtils.mkdir_p(File.join(tree, "cache/ro"))
      File.write(File.join(tree, "cache/ro/x"), "")
      File.chmod(0o500, File.join(tree, "cache/ro"))
    end
    refute File.exist?(leftover)
  end

  def test_repository_listing_past_the_command_limit_is_not_a_failure
    long = File.join(*Array.new(3) { |n| n.to_s * 200 })
    FileUtils.mkdir_p(File.join(@repo, long))
    2_500.times { |n| File.write(File.join(@repo, long, "#{n}_#{'f' * 190}.rb"), "") }
    @git.commit(@repo, "many files")
    assert_operator @git.call(@repo, "ls-files", "--stage").bytesize, :>, Giraffe::Command::LIMIT
    assert_equal @git.head(@repo), @git.fingerprint(@repo)["head"]
    assert_includes @git.tracked_paths(@repo), "app.rb"
  end

  def test_writer_rewriting_a_big_file_is_billed_and_goes_on
    lines = Array.new(30_000) { |n| "base line #{n} #{'x' * 60}\n" }.join
    File.write(File.join(@repo, "package-lock.json"), lines)
    commit_base("a lock file")
    data = script
    data["build"][0]["writes"]["package-lock.json"] = lines.gsub("base", "next")
    data["build"][0]["cost_usd"] = 0.4
    run = start
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_in_delta 0.4, spent(run)
  end

  def test_diff_too_big_for_a_prompt_reaches_the_model_as_a_summary
    data = script
    data["build"][0]["writes"]["fixtures/snapshot.json"] = %("row": "#{'x' * 60}",\n) * 40_000
    run = start
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    prompt = @runner.calls.find { |call| call[:step] == "review" }[:prompt]
    assert_includes prompt, "too large to include"
    assert_includes prompt, "fixtures/snapshot.json"
    assert_operator prompt.bytesize, :<, 100_000
  end

  def test_command_past_its_limits_says_which_command
    assert_match(/-e timed out/, assert_raises(Giraffe::CommandLimit) { @command.capture([RbConfig.ruby, "-e", "sleep 30"], cwd: @tmp, timeout: 0.2) }.message)
    noisy = [RbConfig.ruby, "-e", 'print "x" * 50']
    assert_match(/-e output exceeds 10 bytes/, assert_raises(Giraffe::CommandLimit) { @command.capture(noisy, cwd: @tmp, limit: 10) }.message)
  end

  def test_run_started_under_an_older_spec_command_stays_readable
    [[], ["rspec"], ["rspec", "--line", "{line}"]].each do |older|
      run = start
      run.update(config: run.state["config"].merge("spec_command" => older))
      assert_equal older, Giraffe::Run.load(run.path).config["spec_command"]
      assert_equal run.id, cli("status", run.path).dig("graph", "run_id")
    end
  end

  def test_tracked_file_a_hook_regenerates_is_not_blamed_on_the_mutation
    File.write(File.join(@repo, "FILES"), "")
    commit_base("manifest")
    install_hook("ls test 2>/dev/null > FILES; exit 0")
    data = script
    data["build"][0]["writes"]["test/x_test.rb"] = pinning_spec
    data["spec_audit"] = [audit_of("test/x_test.rb:1")]
    run = start_with_spec
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal "fail", verification_of(run).dig("spec_audit", "specs", 0, "mutation", "result")
  end

  def test_a_patch_ending_on_its_changed_line_applies_mid_file
    File.write(File.join(@repo, "long.rb"), "one\ntwo\nthree\nfour\n")
    commit_base("long file")
    patch = "diff --git a/long.rb b/long.rb\n--- a/long.rb\n+++ b/long.rb\n@@ -2,2 +2,2 @@\n two\n-three\n+THREE\n"
    Giraffe::Git.new.apply(@repo, patch)
    assert_equal "one\ntwo\nTHREE\nfour\n", File.read(File.join(@repo, "long.rb"))
  end

  def test_mutation_cannot_edit_a_spec_helper_already_changed_by_a_checkout_hook
    FileUtils.mkdir_p(File.join(@repo, "test"))
    File.write(File.join(@repo, "test/helper.rb"), "FAIL = false # original\n")
    commit_base("spec helper")
    install_hook("echo 'FAIL = false # bootstrapped' > test/helper.rb")
    checks = Giraffe::Checks.new(config)
    command = [RbConfig.ruby, "-r", "./test/helper", "-e", "abort 'injected failure' if FAIL"]

    ["FAIL = true # bootstrapped", "FAIL = false # original"].each do |replacement|
      patch = app_patch("puts 'base' # harmless production edit") + <<~PATCH
        diff --git a/test/helper.rb b/test/helper.rb
        --- a/test/helper.rb
        +++ b/test/helper.rb
        @@ -1 +1 @@
        -FAIL = false # bootstrapped
        +#{replacement}
      PATCH
      error = assert_raises(Giraffe::InvalidOutput) { mutation_runner(checks).prove(patch, command) }
      assert_includes error.message, "test/helper.rb"
    end
  end

  def test_what_a_hook_leaves_cannot_pass_for_a_mutation
    File.write(File.join(@repo, "manifest.rb"), "")
    commit_base("manifest")
    install_hook("ls test 2>/dev/null > manifest.rb; exit 0")
    data = script
    data["build"][0]["writes"]["test/x_test.rb"] = pinning_spec
    refused = audit_of("test/x_test.rb:1", app_mutation.sub("broken", "fixed"))
    data["spec_audit"] = [{"output" => refused, "cost_usd" => 0.25}, audit_of("test/x_test.rb:1")]
    runner = Giraffe::Runners::Scripted.new(data)
    run = start_with_spec
    assert_match(/changed nothing/, assert_raises(Giraffe::InvalidOutput) { execute(run, runner) }.message)
    execute(run, runner)
    assert_equal "draft_pr", run.state["status"]
  end

  def test_build_cannot_edit_the_hooks_a_checkout_will_run
    {".githooks/post-checkout" => ".githooks/", "hooks/post-checkout" => "./hooks", ".husky/post-checkout" => nil}.each do |path, configured|
      FileUtils.mkdir_p(File.join(@repo, File.dirname(path)))
      File.write(File.join(@repo, path), "#!/bin/sh\nexit 0\n")
      commit_base("hooks in the tree")
      @git.call(@repo, "config", "core.hooksPath", configured) if configured
      data = script
      data["build"][0]["writes"][path] = "#!/bin/sh\nenv > /tmp/stolen\n"
      error = assert_raises(Giraffe::Error) { execute(start, data) }
      assert_match(/protected files: #{Regexp.escape(path)}/, error.message)
      @git.call(@repo, "config", "--unset", "core.hooksPath") if configured
    end
    assert_empty @github.calls
  end

  def test_publishing_runs_no_push_hook
    ran = File.join(@tmp, "pre-push-ran")
    install_hook("touch #{ran}", name: "pre-push")
    run = start
    execute(run)
    assert_equal "draft_pr", run.state["status"]
    refute File.exist?(ran)
  end

  def test_feedback_to_build_leaves_out_the_raw_mutation_proofs
    data = bug_script
    first = copy(data["audit"][0])
    first["clauses"][0] = {"clause_id" => clauses[0], "verdict" => "unmet", "reason" => "Greeting needs another adjustment"}
    data["audit"] = [first, data["audit"][0]]
    fixed = data["build"][0]["writes"].fetch("app.rb")
    data["build"] << {"output" => {"questions" => [], "summary" => "Addressed acceptance finding"}, "writes" => {"app.rb" => "#{fixed.chomp}\n# adjusted\n"}}
    data["review"] << data["review"][0]
    data["spec_audit"] << data["spec_audit"][0]
    run = start_bug
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    feedback = run.state.dig("runtime", "verification_feedback")
    refute feedback.key?("mutation_proofs")
    assert feedback.key?("spec_audit"), "BUILD still hears what the audit concluded"
  end

  def test_outputs_of_finished_attempts_do_not_accumulate_in_state
    big = "finding " * 25_000
    data = script
    data["triage"][0]["summary"] = big
    data["investigate"].each { |output| output["summary"] = big }
    data["review"][0]["summary"] = big
    data["audit"][0]["clauses"][0]["evidence"][0]["note"] = big
    run = start
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_operator JSON.generate(run.state).bytesize, :<, 500_000
  end

  class Crash < Exception; end

  def test_crash_between_builds_two_saves_preserves_the_review_history_after_a_fix
    %w[self_review build_manifest].each do |family|
      crashing = Class.new(Giraffe::Harness) do
        define_method(:put) { |name, *args, **options| super(name, *args, **options).tap { raise Crash if name == family } }
      end
      data = script
      data["review"].unshift({"questions" => [], "summary" => "Needs a fix", "findings" => [
        {"id" => "greeting", "severity" => "blocking", "file" => "app.rb", "reason" => "Adjust the greeting"}
      ]})
      data["build"] << {"output" => {"questions" => [], "summary" => "Addressed review"}, "writes" => {"app.rb" => "puts 'fixed again'\n"}}
      runner = Giraffe::Runners::Scripted.new(data)
      run = start(checks: [[RbConfig.ruby, "-e", "puts Process.clock_gettime(Process::CLOCK_MONOTONIC); #{'abort "wrong" unless File.read("app.rb").include?("fixed")'}"]])
      assert_raises(Crash) { crashing.new(run, runner: runner, github: @github).run }
      saved = run.coordinator.snapshot["artifacts"].find { |row| row["family"] == "self_review" }
      review_path = File.join(run.directory, saved.fetch("content_ref"))
      review = File.read(review_path)
      assert_equal 2, JSON.parse(review).fetch("reviews").length

      resumed = Giraffe::Run.load(run.path)
      execute(resumed, runner)
      assert_equal "draft_pr", resumed.state["status"], "after a crash following #{family}"
      assert_equal review, File.read(review_path)
      assert_equal 2, runner.calls.count { |call| call[:step] == "review" }, "the saved review needs no further model call"
    end
  end

  def test_error_matching_the_secret_scan_still_records_the_pause
    data = script
    data["triage"] = [Giraffe::Error.new("upstream said: bad credentials ghp_#{'a' * 36}")]
    run = start
    assert_raises(Giraffe::Error) { execute(run, data) }
    assert_equal ["paused", "upstream said: bad credentials [REDACTED]"], Giraffe::Run.load(run.path).state.values_at("status", "error")
  end

  def test_refusal_quoting_a_key_header_split_across_lines_is_still_stored
    data = bug_script
    split = data["reproduce"][0].merge("source" => %(puts "-----BEGIN\\nPRIVATE KEY-----"; exit 3))
    assert_resume_asks_again("reproduce", data, split, /could not reproduce/)
  end

  def test_spec_that_passes_with_the_mutation_applied_cannot_publish
    data = script
    data["build"][0]["writes"]["test/x_test.rb"] = "exit 0\n"
    with_fix_rounds(data, 1, "test/x_test.rb" => pinning_spec)
    data["spec_audit"] = [audit_of("test/x_test.rb:1")] * 2
    run = start_with_spec
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 2, run.coordinator.snapshot["attempts"].values.count { |attempt| attempt["node"] == "BUILD" }
    assert_includes @runner.calls.select { |call| call[:step] == "build" }.last[:prompt], "passes_without_change"
  end

  {
    "commits" => ->(cwd) { File.write(File.join(cwd, "app.rb"), "puts 'behind'\n"); [["add", "-A"], ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "behind the harness"]] },
    "repoints_origin" => ->(_cwd) { [["remote", "set-url", "origin", "/tmp/elsewhere.git"]] },
    "repoints_its_push_url" => ->(_cwd) { [["remote", "set-url", "--push", "origin", "/tmp/elsewhere.git"]] },
    "switches_branch" => ->(_cwd) { [["switch", "-qc", "elsewhere"]] }
  }.each do |label, act|
    define_method("test_writer_that_#{label}_is_stopped_and_still_billed") do
      git = @git
      data = script
      data["build"] = [lambda { |request|
        act.call(request[:cwd]).each { |args| git.call(request[:cwd], *args) }
        {"output" => {"questions" => [], "summary" => "Done"}, "cost_usd" => 0.4}
      }]
      run = start
      assert_match(/writer changed repository identity/, assert_raises(Giraffe::Error) { execute(run, data) }.message)
      assert_in_delta 0.4, spent(run)
      assert_empty @github.calls
    end
  end

  def test_runner_is_given_the_schema_and_limit_of_its_role
    run = start(call_budget_usd: 1.5)
    assert_raises(Giraffe::Error) { execute(run, {"triage" => [triage]}) }
    call = @runner.calls.first
    assert_equal JSON.parse(File.read(File.join(ROOT, "schemas/triage.json"))), call[:schema]
    assert_equal 1.5, call[:budget_usd]
  end

  def test_kept_output_is_not_paid_for_again_but_is_checked_again
    data = script
    data["investigate"][1] = Giraffe::Error.new("interrupted")
    data["investigate"] << data["investigate"][0]
    runner = Giraffe::Runners::Scripted.new(data)
    run = start
    assert_raises(Giraffe::Error) { execute(run, runner) }
    key, kept = Giraffe::CallLedger.new(run).entries.find { |_key, entry| entry["role"] == "investigate" && entry["output"] }
    run.checkpoint_entry("calls", key, kept.merge("output" => {"questions" => []}))
    asked = runner.calls.length
    assert_match(/summary is required/, assert_raises(Giraffe::InvalidOutput) { execute(run, runner) }.message)
    assert_equal asked, runner.calls.length
  end

  def test_call_ledger_keeps_a_reservation_until_a_usable_bill_replaces_it
    ledger = Giraffe::CallLedger.new(start)
    reservation = ledger.reserve("key", "triage", 3.0)
    assert_equal 3.0, ledger.spent
    [-1.0, Float::INFINITY, Float::NAN, nil, "1"].each do |cost|
      ledger.failed(reservation, {"cost_usd" => cost})
      assert_raises(Giraffe::InvalidOutput) { ledger.finished(reservation, {"cost_usd" => cost}) }
      assert_equal 3.0, ledger.spent
    end
    ledger.failed(reservation, nil)
    assert_equal 3.0, ledger.spent
    ledger.finished(reservation, {"cost_usd" => 0.5})
    assert_equal 0.5, ledger.spent
  end

  def test_call_ledger_outcomes_carry_no_charge_and_leave_with_their_attempt
    ledger = Giraffe::CallLedger.new(start)
    first = Giraffe::Model::Request.new(role: "triage", attempt: "first", unit: "main", inputs: {}, cwd: @repo, writable: false)
    later = first.with(attempt: "later")
    ledger.keep("kept", first, {"questions" => []})
    ledger.refuse("refused", later, "bad token ghp_#{'a' * 36}")
    reservation = ledger.reserve("kept", "triage", 1.0)
    assert_equal({"questions" => []}, ledger.output("kept"))
    assert_equal "bad token [REDACTED]", ledger.refusal("refused")
    assert_equal 1.0, ledger.spent
    ledger.retire_outcomes("later")
    assert_nil ledger.output("kept")
    assert_equal "bad token [REDACTED]", ledger.refusal("refused")
    assert_equal 1.0, ledger.entries[reservation]["charge"], "what was spent stays"
  end
end
