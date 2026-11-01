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
    assert_equal 0.12, run.state.dig("runtime", "calls").values.sum { |call| call["charge"] }, "an invalid result still costs what it reported"
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
    assert_equal 0.25, run.state.dig("runtime", "calls").values.sum { |call| call.fetch("charge", 0.0) }
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

  def test_probe_that_hangs_is_asked_again_on_resume
    data = bug_script
    assert_resume_asks_again("reproduce", data, data["reproduce"][0].merge("source" => "sleep 30"), /got exit 124/, check_timeout: 2)
  end

  def test_probe_cannot_touch_the_worktree
    data = bug_script
    data["reproduce"][0]["source"] = 'File.write("scratch.txt", "x"); ' + data["reproduce"][0]["source"]
    run = start_bug
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    refute File.exist?(File.join(run.directory, "worktree", "scratch.txt"))
  end

  def test_regression_spec_that_is_not_a_plain_path_is_asked_again_on_resume
    data = bug_script
    assert_resume_asks_again("reproduce", data, data["reproduce"][0].merge("regression_spec" => "test/greeting_test.rb:1"), /must be a file path/)
  end

  def test_regression_spec_outside_the_worktree_is_asked_again_on_resume
    data = bug_script
    assert_resume_asks_again("reproduce", data, data["reproduce"][0].merge("regression_spec" => "../outside_test.rb"), /invalid relative proof path/)
  end

  def test_regression_spec_naming_a_directory_is_asked_again_on_resume
    data = bug_script
    assert_resume_asks_again("reproduce", data, data["reproduce"][0].merge("regression_spec" => "test/"), /must be a file path/)
  end

  def test_gitignored_regression_spec_is_asked_again_on_resume
    File.write(File.join(@repo, ".gitignore"), "generated/\n")
    data = bug_script
    assert_resume_asks_again("reproduce", data, data["reproduce"][0].merge("regression_spec" => "generated/greeting_test.rb"), /gitignored/)
  end

  def test_probe_printing_a_token_is_still_asked_again_with_a_reason
    data = bug_script
    leak = data["reproduce"][0].merge("source" => %(puts "ghp_" + "a" * 36; exit 1))
    assert_resume_asks_again("reproduce", data, leak, /could not reproduce.*REDACTED/)
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

  def test_mutation_cannot_add_a_file_that_is_not_source
    assert_mutation_refused(MUTATION + new_file_patch("boom.txt"))
  end

  def test_mutation_cannot_add_a_new_spec
    assert_mutation_refused(MUTATION + new_file_patch("test/boom_test.rb"))
  end

  def test_mutation_cannot_add_test_support_code
    assert_mutation_refused(MUTATION + new_file_patch("test/support/boom.rb"))
  end

  def test_mutation_cannot_add_a_source_file_an_autoloader_would_pick_up
    assert_mutation_refused(new_file_patch("lib/boom.rb"))
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

  def test_spec_audit_citing_a_line_past_the_end_is_asked_again_on_resume
    data = bug_script
    refused = copy(data["spec_audit"][0])
    refused["specs"][0]["ref"] = "test/greeting_test.rb:99"
    assert_resume_asks_again("spec_audit", data, refused, /real changed spec and line/)
  end

  def test_spec_audit_citing_an_unchanged_file_is_asked_again_on_resume
    data = bug_script
    refused = copy(data["spec_audit"][0])
    refused["specs"][0]["ref"] = "app.rb:1"
    assert_resume_asks_again("spec_audit", data, refused, /real changed spec and line/)
  end

  def test_only_production_source_can_be_mutated
    %w[app.rb lib/a/b.rb src/x.ts pkg/main.go src/Main.java lib/latest.py app/models/lab_test.rb src/ABTest.java src/app.config.ts
       app/views/a.erb src/App.vue src/Contest.java].each do |path|
      assert PrGraph::SpecAuditContract.production_source?(path), "#{path} is production source"
    end
    %w[.hidden.rb lib/.hidden.rb notes.txt Gemfile spec/a_spec.rb test/a_test.rb src/a.spec.ts test/support/boom.rb tests/conftest.py
       conftest.py spec_helper.rb test_helper.rb __tests__/x.js config/environments/test.rb jest.config.js pkg/x_test.go lib/x_test.py
       test_x.py src/FooTest.java].each do |path|
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
    assert_match(/spec-a fails from a clean checkout/, error.message)
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

  def test_files_a_checkout_hook_writes_are_not_blamed_on_the_mutation
    File.write(File.join(@repo, ".gitignore"), "generated/\n")
    hook = File.join(@repo, ".git/hooks/post-checkout")
    File.write(hook, "#!/bin/sh\nmkdir -p generated && echo x > generated/hook.txt\n")
    File.chmod(0o755, hook)
    data = bug_script
    run = start_bug
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal 1, @runner.calls.count { |call| call[:step] == "spec_audit" }
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
    assert_equal run.config["call_budget_usd"], run.state.dig("runtime", "calls").values.sum { |call| call.fetch("charge", 0.0) }
  end

  def test_failed_call_bills_what_it_reported
    failure = Giraffe::Error.new("runner failed")
    failure.usage = {"cost_usd" => 0.5, "turns" => 1}
    data = script
    data["triage"] = [failure]
    run = start
    assert_raises(Giraffe::Error) { execute(run, data) }
    entry = run.state.dig("runtime", "calls").values.first
    assert_equal [0.5, "failed"], entry.values_at("charge", "state")
  end

  def test_run_budget_limits_later_calls_and_stops_once_spent
    thin = {"questions" => [], "summary" => "thin"}
    data = script
    data["triage"] = [{"output" => thin, "cost_usd" => 0.25}, {"output" => thin, "cost_usd" => 0.05}, triage]
    runner = Giraffe::Runners::Scripted.new(data)
    run = start(run_budget_usd: 0.3)
    2.times { assert_raises(Giraffe::InvalidOutput) { execute(run, runner) } }
    assert_in_delta 0.05, runner.calls.last[:budget_usd]
    assert_match(/budget exhausted/, assert_raises(Giraffe::Error) { execute(run, runner) }.message)
    assert_equal 2, runner.calls.length
  end

  def test_token_in_check_output_does_not_stop_a_red_verify
    data = script
    first = copy(data["audit"][0])
    first["clauses"][0] = {"clause_id" => clauses[0], "verdict" => "unmet", "reason" => "Greeting needs another adjustment"}
    data["audit"].unshift(first)
    data["build"] << {"output" => {"questions" => [], "summary" => "Addressed acceptance finding"}, "writes" => {"app.rb" => "puts 'fixed again'\n"}}
    data["review"] << data["review"][0]
    run = start(checks: [[RbConfig.ruby, "-e", %(puts "ghp_" + "a" * 36; abort "wrong" unless File.read("app.rb").include?("fixed"))]])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
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

  def test_spec_command_can_name_the_line_in_its_own_argument
    data = bug_script
    runner = "abort 'empty argument' if ARGV.any?(&:empty?); load ARGV[0]"
    run = start_bug(spec_command: [RbConfig.ruby, "-e", runner, "{spec}", "{line}"])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal "pass", verification_of(run).dig("regression", "candidate", "result")
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

  def test_whole_file_spec_run_drops_the_line_from_the_documented_spec_command
    data = bug_script
    # Like rspec, refuses a location whose line is empty.
    runner = "abort 'cannot load ' + ARGV[0] if ARGV[0].end_with?(':'); load ARGV[0].split(':').first"
    run = start_bug(spec_command: [RbConfig.ruby, "-e", runner, "{spec}:{line}"])
    execute(run, data)
    assert_equal "draft_pr", run.state["status"]
    assert_equal "pass", verification_of(run).dig("regression", "candidate", "result")
  end

  def test_red_on_an_unchanged_candidate_reaches_the_recurrence_stop
    data = script
    unsure = copy(data["audit"][0])
    unsure["clauses"][0] = {"clause_id" => clauses[0], "verdict" => "unverifiable", "reason" => "Cannot tell from here"}
    data["audit"] = [unsure] * 6
    data["review"] *= 6
    data["build"] += Array.new(5) { {"output" => {"questions" => [], "summary" => "Nothing to change"}} }
    run = start
    error = assert_raises(PrGraph::Coordinator::CoordinatorError) { execute(run, data) }
    assert_match(/recurring failure.*verification/, error.message)
    assert_equal "paused", run.state["status"]
    assert run.coordinator.snapshot.dig("failure_queue", "stopped")
    assert_empty @github.calls
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
