# frozen_string_literal: true

require "digest"
require "json"
require_relative "schema"
require_relative "git"
require_relative "../../scripts/event_log"

module Giraffe
  # Fresh calls with durable results. Reservations count against the budget even if a process dies
  # before receiving its bill. Losing a result cannot silently reset the run's spend.
  class Model
    ROOT = File.expand_path("../..", __dir__)
    def initialize(run, runner, git: Git.new)
      @run, @runner, @git = run, runner, git
    end

    # Returns the output, or with a block, what the block returns after saving or refusing it. A refused
    # output stays billed but is dropped, so resuming asks again and says why instead of replaying it.
    def call(role, attempt:, inputs:, cwd:, writable: false, unit: "main", &accept)
      schema = JSON.parse(File.read(File.join(ROOT, "schemas", "#{role}.json")))
      Schema.check!(schema)
      key = Digest::SHA256.hexdigest(JSON.generate([role, attempt, unit, @git.head(cwd), @run.state["answers"]]))
      cached = ledger[key]
      output = cached && cached["output"] || paid_call(key, {step: role, prompt: prompt(role, inputs, cached && cached["refused"]), schema: schema, cwd: cwd, writable: writable})
      deliver(output, schema, role, attempt, key, &accept)
    end

    private

    def ledger = @run.state.fetch("runtime").fetch("calls", {})

    def billable?(cost) = cost.is_a?(Numeric) && cost.finite? && cost >= 0

    def record(key, value) = @run.checkpoint_entry("calls", key, value)

    def prompt(role, inputs, refusal)
      profiles = @run.config["profiles"].fetch("instructions", []) + @run.config["profiles"].fetch(role, [])
      File.read(File.join(ROOT, "prompts", "#{role}.md")) + "\n\n" + JSON.generate({
        "preferences_and_skills" => profiles, "inputs" => inputs, "human_answers" => @run.state["answers"],
        "previous_output_refused_because" => refusal}.compact)
    end

    def budget
      available = @run.config["run_budget_usd"] - ledger.values.sum { |entry| entry.fetch("charge", 0.0) }
      raise Error, "run budget exhausted; unresolved calls retain their reserved cost" unless available > 0.001
      [@run.config["call_budget_usd"], available].min
    end

    def paid_call(key, request)
      role = request.fetch(:step)
      limit = budget
      # A new entry is used on retries, retaining any previous unknown charge.
      reservation = "#{key}:#{SecureRandom.uuid}"
      before = @git.fingerprint(request.fetch(:cwd))
      record(reservation, {"role" => role, "charge" => limit, "state" => "started"})
      result = @runner.call(**request, budget_usd: limit)
      guard_repository!(request, before)
      usage = result.fetch("usage")
      raise InvalidOutput, "runner returned an invalid cost" unless billable?(usage.fetch("cost_usd"))
      # Billed before validating: an invalid result still cost what it reported.
      record(reservation, {"role" => role, "charge" => usage["cost_usd"], "state" => "finished", "usage" => usage})
      result.fetch("output")
    rescue Error => error
      usage = error.usage
      record(reservation, {"role" => role, "charge" => usage["cost_usd"], "state" => "failed", "usage" => usage}) if reservation && usage && billable?(usage["cost_usd"])
      raise
    end

    def guard_repository!(request, before)
      cwd = request.fetch(:cwd)
      return @git.unchanged!(cwd, before) unless request.fetch(:writable)
      fields = %w[head branch common_git_dir origin push_origin]
      raise Error, "writer changed repository identity or committed outside the harness" unless before.slice(*fields) == @git.fingerprint(cwd).slice(*fields)
    end

    def deliver(output, schema, role, attempt, key)
      Schema.validate!(schema, output)
      record(key, {"role" => role, "charge" => 0.0, "output" => output}) unless ledger.dig(key, "output")
      questions!(output, role, attempt, key)
      block_given? ? yield(output) : output
    rescue InvalidOutput, PrGraph::ContentError => error
      record(key, {"role" => role, "charge" => 0.0, "refused" => error.message})
      raise
    end

    def questions!(output, role, attempt, key)
      return if output.fetch("questions").empty?
      questions = output["questions"].each_with_index.map do |text, i|
        {"id" => "#{key[0, 12]}-#{i + 1}", "text" => text, "role" => role, "attempt_id" => attempt}
      end
      @run.update(status: "waiting_for_answers", questions: questions)
      raise Parked, "waiting for a person's answer"
    end
  end
end
