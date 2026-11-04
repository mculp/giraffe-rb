# frozen_string_literal: true

require_relative "../safe_path"

module Giraffe
  module Steps
    module Verify
      def step_verify
        candidate = @git.head(worktree)
        @git.clean!(worktree)
        if (saved = attempted_artifact("verification"))
          finish_verification(saved)
          return
        end
        checks = read_only_checks(@run.config["checks"] + @run.config["lint"])
        content = {"candidate_sha" => candidate, "checks" => checks}
        reason = if checks.all? { |check| check["exit_code"].zero? }
                   @git.read_only(worktree) { screen_rejection(content, candidate) || audit_candidate(content, candidate) }
                 else
                   "Executable verification failed"
                 end
        content["failures"] = reason ? 1 : 0
        content["reason"] = reason
        put("verification", content, candidate: candidate, perspective: "automated_check", covered: clause_ids)
        finish_verification(content)
      end

      def finish_verification(content)
        if content["failures"].positive?
          # Without the raw proofs: their outcomes are in spec_audit, and a proof per example can outgrow the state.
          checkpoint("verification_feedback", content.except("mutation_proofs").merge("answers_seen" => @run.state["answers"].size))
          # Per attempt: a fix batch can leave the candidate alone, and that red still counts toward the recurrence stop.
          @run.coordinator.fail(@node, @attempt, reason: content.fetch("reason"), failure_id: "verification", revision: "#{content.fetch('candidate_sha')}:#{@attempt}")
        else
          finish
        end
      end

      # Fills in what the screen checks did and left, and returns why that rules the candidate out, or nil.
      def screen_rejection(content, candidate)
        commands = @run.config["screen_checks"].to_a
        return ask_a_person_to_look(candidate) if commands.empty?
        screen_checks = ScreenChecks.new(git: @git, checks: @checks, worktree: worktree, commands: commands)
        results, content["screenshots"] = screen_checks.run(candidate, File.join(@run.directory, "screenshots", @attempt))
        content["checks"] += results
        failed = results.find { |result| !result["exit_code"].zero? }
        return "A screen check failed: #{Command.tail(failed['excerpt'])}" if failed
        "This ticket changes what people see and its screen checks left no screenshot" if ui_ticket? && content["screenshots"].empty?
      end

      # Nothing here can see a screen, so on a ticket people will see, someone looks before an audit is paid for.
      # By candidate: what they saw on one says nothing about the next.
      def ask_a_person_to_look(candidate)
        id = "look-#{candidate}"
        return if !ui_ticket? || @run.state["answers"].key?(id)
        ask_a_person(id, "This ticket changes what people see, and no screen_checks are declared, so nothing in this run can see it. Please look at #{candidate} " \
                         "on the narrowest screen this app supports, in each state the ticket adds at its longest, and say what you saw: anything cut off by the " \
                         "screen's edge, overlapping or squeezed.")
      end

      def ui_ticket? = runtime["ui"] || artifact("triage_brief")["ui"]

      # Fills in the audits and returns why the candidate does not pass them, or nil.
      def audit_candidate(content, candidate)
        shots = content["screenshots"].to_a
        # Deliberately exclude the implementation and test plans from the acceptance call.
        ask("audit", {"triage_brief" => artifact("triage_brief"), "diff" => @git.diff(worktree, base_sha), "checks" => content["checks"], "screenshots" => shots}) do |output|
          content["ac_audit"] = output.slice("clauses", "missed").merge("candidate_sha" => candidate, "inputs" => ["triage_brief"])
          ac_audit_contract.validate_shape!(content, clause_ids: clause_ids, candidate_sha: candidate)
          content["screens"] = rulings(output, shots)
        end
        # Before the spec audit, which is not worth paying for on a candidate that has to change.
        broken = content["screens"].select { |row| row["verdict"] == "broken" }
        return "Screens look broken: #{broken.map { |row| "#{row['name']}: #{row['note']}" }.join(' ')}" if broken.any?
        content["spec_audit"], content["mutation_proofs"] = audit_specs(candidate)
        content["regression"] = regression(candidate) if regression_spec_written?(candidate)
        contract_rejection(content)
      rescue BaselineFailed => error
        error.message
      end

      # A reproduced bug owes a regression spec the candidate adds or changes. Without one there is no run to
      # record, so the contract sends VERIFY red for BUILD to write it.
      def regression_spec_written?(candidate)
        report = artifact("repro_report")
        return false unless report["status"] == "reproduced"
        @git.call(worktree, "diff", "--name-only", "--diff-filter=AMR", base_sha, candidate).lines.map(&:strip).include?(report.fetch("rerun"))
      end

      # One for every picture: a suite can pass with a screen no one would ship, and only a look can say.
      def rulings(output, shots)
        rows = output.fetch("screens")
        names = shots.map { |shot| shot["name"] }
        raise InvalidOutput, "screens must rule once on each screenshot, by name: #{names.join(', ')}" unless rows.map { |row| row["name"] }.sort == names.sort
        rows
      end

      def contract_rejection(content)
        @run.coordinator.validate_verification!(content, worktree: worktree)
        "Acceptance criteria remain unverifiable" if content.dig("ac_audit", "clauses").any? { |row| row["verdict"] == "unverifiable" }
      rescue PrGraph::ContractError => error
        error.message
      end

      def spec_command(ref)
        path, line = ref.split(":", 2)
        arguments = line ? @run.config["spec_command"] : whole_file_arguments
        arguments.map { |arg| arg.gsub("{spec}", path).gsub("{line}", line.to_s) }
      end

      # "path:" is not a location a framework can load, and an argument carrying only the line means nothing.
      def whole_file_arguments
        arguments = @run.config["spec_command"].map { |arg| arg.gsub("{spec}:{line}", "{spec}") }
        arguments.reject { |arg| arg.include?("{line}") && !arg.include?("{spec}") }
      end

      # The spec audit section, and beside it the full command results: the shared contract consumes its fixed
      # fields, so those results are not reported as model-authored mutation verdicts.
      def audit_specs(candidate)
        section = {"candidate_sha" => candidate, "base_sha" => base_sha, "specs" => []}
        paths = PrGraph::SpecAuditContract.changed_spec_paths(worktree, base_sha, candidate)
        return section, [] if paths.empty?
        ask("spec_audit", {"test_plan" => artifact("test_plan"), "diff" => @git.diff(worktree, base_sha), "changed_specs" => paths}) do |output|
          specs = output.fetch("specs")
          proofs = mutation_proofs(specs, candidate, paths)
          audited = specs.zip(proofs).map do |spec, proof|
            spec.slice("ref", "behavior", "classes").merge("mutation" => {"change" => spec.fetch("patch"), "result" => proof["exit_code"].zero? ? "pass" : "fail"})
          end
          audit = section.merge("specs" => audited)
          spec_audit_contract.validate_shape!({"spec_audit" => audit}, candidate_sha: candidate, base_sha: base_sha, spec_paths: paths)
          [audit, proofs]
        end
      end

      def mutation_proofs(specs, candidate, paths)
        runner = MutationRunner.new(git: @git, checks: @checks, worktree: worktree, candidate: candidate)
        specs.map do |spec|
          require_changed_spec_line!(spec.fetch("ref"), paths)
          runner.prove(spec.fetch("patch"), spec_command(spec["ref"]))
        end
      end

      def require_changed_spec_line!(ref, paths)
        path, line = ref.split(":", 2)
        return if paths.include?(path) && line.to_s.match?(/\A[1-9][0-9]*\z/) && line.to_i <= File.readlines(SafePath.new(worktree).file(path)).length
        raise InvalidOutput, "spec audit must cite a real changed spec and line: #{ref}"
      end

      # Both sides run from a clean checkout, so missing generated files cannot pass for the bug being red.
      def regression(candidate)
        path = artifact("repro_report").fetch("rerun")
        source = File.binread(SafePath.new(worktree).file(path))
        fixed = @git.at_commit(worktree, candidate) { |tree| @checks.run(tree, [spec_command(path)]).first }
        broken = @git.at_commit(worktree, base_sha) do |tree|
          target = SafePath.new(tree).target(path)
          FileUtils.mkdir_p(File.dirname(target))
          File.binwrite(target, source)
          @checks.run(tree, [spec_command(path)]).first
        end
        {"spec" => path, "base" => regression_result(base_sha, broken), "candidate" => regression_result(candidate, fixed)}
      end

      def regression_result(sha, result)
        excerpt = result["excerpt"].strip.empty? ? "exit #{result['exit_code']}" : result["excerpt"]
        {"sha" => sha, "result" => result["exit_code"].zero? ? "pass" : "fail", "excerpt" => excerpt}
      end
    end
  end
end
