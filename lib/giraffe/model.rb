# frozen_string_literal: true

require "digest"
require "json"
require_relative "schema"
require_relative "git"

module Giraffe
  # Fresh calls with durable results. Reservations count against the budget even if a process dies
  # before receiving its bill. Losing a result cannot silently reset the run's spend.
  class Model
    ROOT = File.expand_path("../..", __dir__)
    def initialize(run, runner, git: Git.new)
      @run, @runner, @git = run, runner, git
    end

    def call(role, attempt:, inputs:, cwd:, writable: false, unit: "main")
      config = @run.config
      schema = JSON.parse(File.read(File.join(ROOT, "schemas", "#{role}.json")))
      Schema.check!(schema)
      key = Digest::SHA256.hexdigest(JSON.generate([role, attempt, unit, @git.head(cwd), @run.state["answers"]]))
      calls = @run.state.fetch("runtime").fetch("calls", {})
      cached = calls[key]
      if cached && cached["output"]
        Schema.validate!(schema, cached["output"])
        return questions!(cached["output"], role, attempt, key)
      end
      spent = calls.values.sum { |entry| entry.fetch("charge", 0.0) }
      available = config["run_budget_usd"] - spent
      raise Error, "run budget exhausted; unresolved calls retain their reserved cost" unless available > 0.001
      budget = [config["call_budget_usd"], available].min
      profiles = config["profiles"].fetch("instructions", []) + config["profiles"].fetch(role, [])
      prompt = File.read(File.join(ROOT, "prompts", "#{role}.md")) + "\n\n" + JSON.generate(
        "preferences_and_skills" => profiles, "inputs" => inputs, "human_answers" => @run.state["answers"])
      # A new entry is used on retries, retaining any previous unknown charge.
      reservation = "#{key}:#{SecureRandom.uuid}"
      before = @git.fingerprint(cwd)
      record(reservation, {"role" => role, "charge" => budget, "state" => "started"})
      result = @runner.call(step: role, prompt: prompt, schema: schema, cwd: cwd, writable: writable, budget_usd: budget)
      if writable
        after = @git.fingerprint(cwd)
        fields = %w[head branch common_git_dir origin push_origin]
        raise Error, "writer changed repository identity or committed outside the harness" unless before.slice(*fields) == after.slice(*fields)
      else
        @git.unchanged!(cwd, before)
      end
      usage = result.fetch("usage")
      cost = usage.fetch("cost_usd")
      raise InvalidOutput, "runner returned an invalid cost" unless cost.is_a?(Numeric) && cost.finite? && cost >= 0
      Schema.validate!(schema, result.fetch("output"))
      record(reservation, {"role" => role, "charge" => cost, "state" => "finished", "usage" => usage})
      record(key, {"role" => role, "charge" => 0.0, "output" => result["output"]})
      questions!(result["output"], role, attempt, key)
    rescue StandardError => error
      if reservation && error.respond_to?(:usage)
        usage = error.usage
        cost = usage["cost_usd"]
        record(reservation, {"role" => role, "charge" => cost, "state" => "failed", "usage" => usage}) if cost.is_a?(Numeric) && cost.finite? && cost >= 0
      end
      raise
    end

    private

    def record(key, value)
      runtime = @run.state.fetch("runtime")
      @run.update(runtime: runtime.merge("calls" => runtime.fetch("calls", {}).merge(key => value)))
    end

    def questions!(output, role, attempt, key)
      return output if output.fetch("questions").empty?
      questions = output["questions"].each_with_index.map do |text, i|
        {"id" => "#{key[0, 12]}-#{i + 1}", "text" => text, "role" => role, "attempt_id" => attempt}
      end
      @run.update(status: "waiting_for_answers", questions: questions)
      raise Parked, "waiting for a person's answer"
    end
  end
end
