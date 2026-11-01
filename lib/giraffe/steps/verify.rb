# frozen_string_literal: true

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
                   @git.read_only(worktree) { audit_candidate(content, candidate, checks) }
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
          checkpoint("verification_feedback", content)
          # Per attempt: a fix batch can leave the candidate alone, and that red still counts toward the recurrence stop.
          @run.coordinator.fail(@node, @attempt, reason: content.fetch("reason"), failure_id: "verification", revision: "#{content.fetch('candidate_sha')}:#{@attempt}")
        else
          finish
        end
      end

      # Fills in the audits and returns why the candidate does not pass them, or nil.
      def audit_candidate(content, candidate, checks)
        # Deliberately exclude the implementation and test plans from the acceptance call.
        ask("audit", {"triage_brief" => artifact("triage_brief"), "diff" => @git.diff(worktree, base_sha), "checks" => checks}) do |output|
          content["ac_audit"] = output.slice("clauses", "missed").merge("candidate_sha" => candidate, "inputs" => ["triage_brief"])
          ac_audit_contract.validate_shape!(content, clause_ids: clause_ids, candidate_sha: candidate)
        end
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

      def contract_rejection(content)
        @run.coordinator.validate_verification!(content, worktree: worktree)
        "Acceptance criteria remain unverifiable" if content.dig("ac_audit", "clauses").any? { |row| row["verdict"] == "unverifiable" }
      rescue PrGraph::ContractError => error
        error.message
      end

      def spec_command(ref)
        path, line = ref.split(":", 2)
        raise Error, "spec_command must be configured to run changed specs" if @run.config["spec_command"].empty?
        # A whole-file run has no line, and "path:" is not a location a framework can load.
        @run.config["spec_command"].map { |arg| arg.gsub("{spec}:{line}", line ? ref : path).gsub("{spec}", path).gsub("{line}", line.to_s) }
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
        @git.at_commit(worktree, candidate) do |tree|
          runner = MutationRunner.new(git: @git, checks: @checks, tree: tree, candidate: candidate)
          specs.map do |spec|
            require_changed_spec_line!(spec.fetch("ref"), paths)
            runner.prove(spec.fetch("patch"), spec_command(spec["ref"]))
          end
        end
      end

      def require_changed_spec_line!(ref, paths)
        path, line = ref.split(":", 2)
        return if paths.include?(path) && line.to_s.match?(/\A[1-9][0-9]*\z/) && line.to_i <= File.readlines(safe_file(worktree, path)).length
        raise InvalidOutput, "spec audit must cite a real changed spec and line: #{ref}"
      end

      # Both sides run from a clean checkout, so missing generated files cannot pass for the bug being red.
      def regression(candidate)
        path = artifact("repro_report").fetch("rerun")
        source = File.binread(safe_file(worktree, path))
        fixed = @git.at_commit(worktree, candidate) { |tree| @checks.run(tree, [spec_command(path)]).first }
        broken = @git.at_commit(worktree, base_sha) do |tree|
          target = safe_file(tree, path, existing: false)
          FileUtils.mkdir_p(File.dirname(target))
          File.binwrite(target, source)
          @checks.run(tree, [spec_command(path)]).first
        end
        {"spec" => path, "base" => regression_result(base_sha, broken), "candidate" => regression_result(candidate, fixed)}
      end

      def regression_result(sha, result)
        {"sha" => sha, "result" => result["exit_code"].zero? ? "pass" : "fail", "excerpt" => result["excerpt"].empty? ? "exit #{result['exit_code']}" : result["excerpt"]}
      end

      # A proof path comes from a model's output, so a bad one is that output's fault.
      def safe_file(root, relative, existing: true)
        root = File.realpath(root)
        inside = "#{root}/"
        raise InvalidOutput, "invalid relative proof path: #{relative}" if relative.start_with?("/", "-") || relative.split("/").any? { |part| %w[. .. .git].include?(part) }
        target = File.expand_path(relative, root)
        raise InvalidOutput, "proof path escapes its worktree: #{relative}" unless target.start_with?(inside)
        if existing
          raise InvalidOutput, "proof file is missing or a symlink: #{relative}" unless File.file?(target) && !File.symlink?(target) && File.realpath(target).start_with?(inside)
        else
          parent = File.dirname(target)
          parent = File.dirname(parent) until File.exist?(parent)
          real_parent = File.realpath(parent)
          raise InvalidOutput, "proof path follows a symlink outside the worktree: #{relative}" unless real_parent == root || real_parent.start_with?(inside)
          raise InvalidOutput, "proof target is a symlink: #{relative}" if File.symlink?(target)
        end
        target
      end
    end
  end
end
