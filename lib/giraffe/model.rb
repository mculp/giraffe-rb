# frozen_string_literal: true

require "digest"
require "json"
require_relative "call_ledger"
require_relative "schema"
require_relative "git"
require_relative "../../scripts/event_log"

module Giraffe
  # Fresh calls with durable results. Reservations count against the budget even if a process dies
  # before receiving its bill. Losing a result cannot silently reset the run's spend.
  class Model
    ROOT = File.expand_path("../..", __dir__)
    Call = Data.define(:role, :attempt, :key, :schema, :cwd, :writable)

    def initialize(run, runner, git: Git.new)
      @run, @runner, @git = run, runner, git
      @ledger = CallLedger.new(run)
    end

    # Returns the output, or with a block, what the block returns after saving or refusing it. A refused
    # output stays billed but is dropped, so resuming asks again and says why instead of replaying it.
    def call(role, attempt:, inputs:, cwd:, writable: false, unit: "main", &accept)
      schema = JSON.parse(File.read(File.join(ROOT, "schemas", "#{role}.json")))
      Schema.check!(schema)
      key = Digest::SHA256.hexdigest(JSON.generate([role, attempt, unit, @git.head(cwd), @run.state["answers"]]))
      call = Call.new(role: role, attempt: attempt, key: key, schema: schema, cwd: cwd, writable: writable)
      output = @ledger.output(key) || paid_call(call, prompt(role, inputs, @ledger.refusal(key)))
      deliver(output, call, &accept)
    end

    private

    def billable?(usage)
      cost = usage && usage["cost_usd"]
      cost.is_a?(Numeric) && cost.finite? && cost >= 0
    end

    def prompt(role, inputs, refusal)
      profiles = @run.config["profiles"].fetch("instructions", []) + @run.config["profiles"].fetch(role, [])
      File.read(File.join(ROOT, "prompts", "#{role}.md")) + "\n\n" + JSON.generate({
        "preferences_and_skills" => profiles, "inputs" => inputs, "human_answers" => @run.state["answers"],
        "previous_output_refused_because" => refusal}.compact)
    end

    def budget
      available = @run.config["run_budget_usd"] - @ledger.spent
      raise Error, "run budget exhausted; unresolved calls retain their reserved cost" unless available > 0.001
      [@run.config["call_budget_usd"], available].min
    end

    def paid_call(call, prompt)
      limit = budget
      # A new entry is used on retries, retaining any previous unknown charge.
      reservation = "#{call.key}:#{SecureRandom.uuid}"
      before = @git.fingerprint(call.cwd)
      @ledger.reserve(reservation, call.role, limit)
      result = @runner.call(step: call.role, prompt: prompt, schema: call.schema, cwd: call.cwd, writable: call.writable, budget_usd: limit)
      guard_repository!(call, before)
      usage = result.fetch("usage")
      raise InvalidOutput, "runner returned an invalid cost" unless billable?(usage)
      # Billed before validating: an invalid result still cost what it reported.
      @ledger.bill(reservation, call.role, "finished", usage)
      result.fetch("output")
    rescue Error => error
      @ledger.bill(reservation, call.role, "failed", error.usage) if reservation && billable?(error.usage)
      raise
    end

    def guard_repository!(call, before)
      return @git.unchanged!(call.cwd, before) unless call.writable
      fields = %w[head branch common_git_dir origin push_origin]
      raise Error, "writer changed repository identity or committed outside the harness" unless before.slice(*fields) == @git.fingerprint(call.cwd).slice(*fields)
    end

    def deliver(output, call)
      Schema.validate!(call.schema, output)
      @ledger.keep(call.key, call.role, output) unless @ledger.output(call.key)
      questions!(output, call)
      block_given? ? yield(output) : output
    rescue InvalidOutput, PrGraph::ContentError => error
      @ledger.refuse(call.key, call.role, error.message)
      raise
    end

    def questions!(output, call)
      return if output.fetch("questions").empty?
      questions = output["questions"].each_with_index.map do |text, i|
        {"id" => "#{call.key[0, 12]}-#{i + 1}", "text" => text, "role" => call.role, "attempt_id" => call.attempt}
      end
      @run.update(status: "waiting_for_answers", questions: questions)
      raise Parked, "waiting for a person's answer"
    end
  end
end
