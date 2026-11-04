# frozen_string_literal: true

require "digest"
require "json"
require_relative "call_ledger"
require_relative "schema"
require_relative "git"
require_relative "runners/task"
require_relative "../../scripts/event_log"

module Giraffe
  # Fresh calls with durable results. Reservations count against the budget even if a process dies
  # before receiving its bill. Losing a result cannot silently reset the run's spend.
  class Model
    ROOT = File.expand_path("../..", __dir__)
    # What a writer may not change, unlike its working tree.
    IDENTITY = %w[head branch common_git_dir origin push_origin].freeze

    # One question for a model: which role, in which attempt and unit of work, about what, and where it may look.
    Request = Data.define(:role, :attempt, :unit, :inputs, :cwd, :writable) do
      def schema = JSON.parse(File.read(File.join(ROOT, "schemas", "#{role}.json"))).tap { |schema| Schema.check!(schema) }
      def instructions = File.read(File.join(ROOT, "prompts", "#{role}.md"))

      # An answer stands for this question, on this commit, given what people have answered so far.
      def key(head, answers) = Digest::SHA256.hexdigest(JSON.generate([role, attempt, unit, head, answers]))

      def for_runner(prompt, budget)
        Runners::Task.new(step: role, prompt: prompt, schema: schema, cwd: cwd, writable: writable, budget_usd: budget)
      end

      def questions(output, key)
        output.fetch("questions").each_with_index.map do |text, index|
          {"id" => "#{key[0, 12]}-#{index + 1}", "text" => text, "role" => role, "attempt_id" => attempt}
        end
      end
    end

    def initialize(run, runner, git: Git.new, ledger: CallLedger.new(run))
      @run, @runner, @git, @ledger = run, runner, git, ledger
    end

    # Returns the output, or with a block, what the block returns after saving or refusing it. A refused
    # output stays billed but is dropped, so resuming asks again and says why instead of replaying it.
    def call(request, &accept)
      key = request.key(@git.head(request.cwd), @run.state["answers"])
      output = @ledger.output(key) || paid_call(request, key)
      deliver(output, request, key, &accept)
    end

    def begin_attempt(attempt) = @ledger.retire_outcomes(attempt)

    private

    def prompt(request, refusal)
      profiles = @run.config["profiles"].fetch("instructions", []) + @run.config["profiles"].fetch(request.role, [])
      request.instructions + "\n\n" + JSON.generate({
        "preferences_and_skills" => profiles, "inputs" => request.inputs, "human_answers" => @run.state["answers"],
        "previous_output_refused_because" => refusal}.compact)
    end

    def budget
      available = @run.config["run_budget_usd"] - @ledger.spent
      raise Error, "run budget exhausted; unresolved calls retain their reserved cost" unless available > 0.001
      [@run.config["call_budget_usd"], available].min
    end

    def paid_call(request, key)
      limit = budget
      task = request.for_runner(prompt(request, @ledger.refusal(key)), limit)
      result = guarded(request) { billed(key, request.role, limit) { @runner.call(task) } }
      result.fetch("output")
    end

    def guarded(request)
      before = @git.fingerprint(request.cwd)
      yield.tap { guard_repository!(request, before) }
    end

    # Billed before its result is judged: a refused result still cost what it reported.
    def billed(key, role, limit)
      reservation = @ledger.reserve(key, role, limit)
      yield.tap { |result| @ledger.finished(reservation, result.fetch("usage")) }
    rescue Error => error
      @ledger.failed(reservation, error.usage)
      raise
    end

    def guard_repository!(request, before)
      return @git.unchanged!(request.cwd, before) unless request.writable
      return if before.slice(*IDENTITY) == @git.fingerprint(request.cwd).slice(*IDENTITY)
      raise Error, "writer changed repository identity or committed outside the harness"
    end

    def deliver(output, request, key)
      keep(output, request, key)
      park_on_questions!(output, request, key)
      block_given? ? yield(output) : output
    rescue InvalidOutput, PrGraph::ContentError => error
      @ledger.refuse(key, request, error.message)
      raise
    end

    def keep(output, request, key)
      Schema.validate!(request.schema, output)
      @ledger.keep(key, request, output) unless @ledger.output(key)
    end

    def park_on_questions!(output, request, key)
      return if output.fetch("questions").empty?
      @run.update(status: "waiting_for_answers", questions: request.questions(output, key))
      raise Parked, "waiting for a person's answer"
    end
  end
end
