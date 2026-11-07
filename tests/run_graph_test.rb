# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "digest"
require "fileutils"
require "rbconfig"
require "tmpdir"
require_relative "../lib/giraffe/graph_view"

# A caller asks a run for the graph it follows. It does not reach through the run's store and event log to the
# contract, so the contract can move without any caller noticing.
class RunGraphTest < Minitest::Test
  GRAPH = JSON.parse(File.read(File.expand_path("../references/execution-contract-v1.json", __dir__))).fetch("graph")

  # A run that offers a view a graph of its own and a sync status, with no event log behind its store: a view
  # that reached through the store for the contract would fail on it.
  class RunWithAGraph < SimpleDelegator
    attr_reader :graph, :store

    def initialize(run, graph)
      super(run)
      @graph = graph
      @store = Object.new.tap { |held| held.define_singleton_method(:sync_status) { {"mode" => "local", "synced" => false} } }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("giraffe-run-graph-test-")
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

  def test_a_run_answers_with_the_graph_its_contract_defines
    graph = @run.graph
    assert_equal GRAPH, graph
    assert_equal %w[nodes dependencies conditional_gates legal_edges], graph.keys
  end

  def test_a_run_asks_its_event_log_for_the_graph
    assert_equal GRAPH, @run.graph
    elsewhere = {"nodes" => %w[ONLY]}
    @run.store.define_singleton_method(:event_log) { Data.define(:contract).new(contract: {"graph" => elsewhere}) }
    assert_equal elsewhere, @run.graph
  end

  def test_a_graph_view_takes_its_definition_from_the_graph_the_run_answers_with
    graph = GRAPH.merge("dependencies" => GRAPH["dependencies"].transform_values { [] }, "legal_edges" => [%w[TRIAGE DONE]])
    snapshot = Giraffe::GraphView.new(RunWithAGraph.new(@run, graph)).snapshot
    assert_equal graph["dependencies"], snapshot["definition"]["dependencies"]
    assert_equal [%w[TRIAGE DONE]], snapshot["definition"]["legal_edges"]
    assert_equal [[]], snapshot["nodes"].map { |row| row["dependencies"] }.uniq
    assert_equal Digest::SHA256.hexdigest(JSON.generate(snapshot["definition"])), snapshot["graph_version"]
  end
end
