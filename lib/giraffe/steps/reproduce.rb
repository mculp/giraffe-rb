# frozen_string_literal: true

require_relative "../command"
require_relative "../errors"
require_relative "reproduce/probe"
require_relative "reproduce/regression_spec"

module Giraffe
  module Steps
    # Makes a reported defect happen again on the base before anyone tries to fix it. A model writes the probe and says
    # what it should do, and the harness runs it, so a reproduction is something the harness saw. A feature has no defect
    # to reproduce, and its report says so.
    class Reproduce
      def call(context)
        @context = context
        # A resume that finds the report already put has only the attempt left to end, and does not run the probe again.
        reproduce unless context.attempted_artifact("repro_report")
        context.finish
      end

      private

      def reproduce
        return not_applicable unless @context.artifact("triage_brief").fetch("bug")
        # The model reads the repo from its normal cwd and returns probe source as structured data.
        @context.ask("reproduce", inputs) { |output| save(output) }
      end

      def inputs = {"investigation" => @context.artifact("investigation_report"), "outcomes" => @context.clause_ids, "base_sha" => @context.base_sha}

      def not_applicable
        @context.put("repro_report", {"status" => "not_applicable", "base_sha" => @context.base_sha, "reason" => "Ticket triage identifies a feature, not a reported defect."})
      end

      # The reproduction is checkpointed before the report is put, so that BUILD has it whenever the report exists.
      def save(output)
        RegressionSpec.new(output.fetch("regression_spec"), git: @context.git, worktree: @context.worktree).check!
        result = probe.run(output.fetch("source"), repo: @context.worktree, sha: @context.base_sha)
        confirm!(output, result)
        @context.checkpoint("reproduction", output)
        @context.put("repro_report", report(output, result))
      end

      def probe = Probe.new(git: @context.git, checks: @context.checks, directory: File.join(@context.run.directory, "probe"))

      def confirm!(output, result)
        return if result["exit_code"] == output["expected_exit"] && result["excerpt"].include?(output["expected_output"])
        raise InvalidOutput, "the harness could not reproduce the reported base behavior: expected exit #{output['expected_exit']} and output containing " \
                             "#{output['expected_output']}, got exit #{result['exit_code']}: #{Command.tail(result['excerpt'])}"
      end

      def report(output, result)
        output.slice("steps", "expected", "observed", "code_path", "clause_ids").merge(
          "status" => "reproduced", "base_sha" => @context.base_sha, "rerun" => output.fetch("regression_spec"),
          "evidence" => [{"command" => "ruby stored-probe.rb", "excerpt" => result["excerpt"]}])
      end
    end
  end
end
