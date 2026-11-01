# frozen_string_literal: true

require "rbconfig"

module Giraffe
  module Steps
    module Preparation
      def step_triage
        @git.clean!(@run.config["repo"])
        ask("triage", {}, cwd: @run.config["repo"]) { |output| put("triage_brief", output.merge("ticket" => @run.state["ticket"])) }
        finish
      end

      def step_worktree
        manifest = @git.worktree(repo: @run.config["repo"], path: worktree,
                                branch: "codex/giraffe-#{@run.id}", base: @run.config["base"])
        checkpoint("base_sha", manifest["base_sha"])
        put("worktree_manifest", manifest)
        finish
      end

      def step_investigate
        reports = %w[ticket prior_art codebase].to_h do |perspective|
          [perspective, ask("investigate", {"perspective" => perspective, "triage" => artifact("triage_brief")}, unit: perspective)]
        end
        put("investigation_report", {"reports" => reports})
        finish
      end

      def step_reproduce
        if attempted_artifact("repro_report")
          finish
          return
        end
        unless artifact("triage_brief").fetch("bug")
          put("repro_report", {"status" => "not_applicable", "base_sha" => base_sha, "reason" => "Ticket triage identifies a feature, not a reported defect."})
          finish
          return
        end
        # The model reads the repo from its normal cwd and returns probe source as structured data.
        ask("reproduce", {"investigation" => artifact("investigation_report"), "outcomes" => clause_ids, "base_sha" => base_sha}) { |output| save_reproduction(output) }
        finish
      end

      def save_reproduction(output)
        # Models write a probe outside the repository. Its bytes are persisted so resuming does not
        # require the old process or a session transcript.
        scratch = File.join(@run.directory, "probe")
        FileUtils.mkdir_p(scratch, mode: 0o700)
        probe = File.join(scratch, "probe.rb")
        File.write(probe, output.fetch("source"), mode: "w", perm: 0o600)
        result = read_only_checks([[RbConfig.ruby, probe]]).fetch(0)
        unless result["exit_code"] == output["expected_exit"] && result["excerpt"].include?(output["expected_output"])
          raise InvalidOutput, "the harness could not reproduce the reported base behavior: the probe exited #{result['exit_code']}"
        end
        checkpoint("reproduction", output)
        report = output.slice("steps", "expected", "observed", "code_path", "clause_ids").merge(
          "status" => "reproduced", "base_sha" => base_sha, "rerun" => output.fetch("regression_spec"),
          "evidence" => [{"command" => "ruby stored-probe.rb", "excerpt" => result["excerpt"]}])
        put("repro_report", report)
      end

      def step_plan
        ask("plan", {"triage" => artifact("triage_brief"), "investigation" => artifact("investigation_report"), "reproduction" => artifact("repro_report")}) do |output|
          @run.coordinator.validate_plan!(output["implementation_plan"], output["test_plan"])
          put("implementation_plan", output.fetch("implementation_plan"))
          put("test_plan", output.fetch("test_plan"))
          checkpoint("ui", output.fetch("ui"))
        end
        finish
      end
    end
  end
end
