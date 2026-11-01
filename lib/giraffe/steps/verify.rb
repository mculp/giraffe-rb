# frozen_string_literal: true

module Giraffe
  module Steps
    module Verify
      SOURCE_FILE = /\.(rb|[jt]sx?|py|go|rs|java|ex|exs)\z/
      TEST_TREE = %r{(\A|/)(spec|tests?|__tests__)/}

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
          @run.coordinator.fail(@node, @attempt, reason: content.fetch("reason"), failure_id: "verification", revision: content.fetch("candidate_sha"))
        else
          finish
        end
      end

      # Fills in the audits and returns why the candidate does not pass them, or nil.
      def audit_candidate(content, candidate, checks)
        # Deliberately exclude the implementation and test plans from the acceptance call.
        audit = ask("audit", {"triage_brief" => artifact("triage_brief"), "diff" => @git.diff(worktree, base_sha), "checks" => checks}) do |output|
          content["ac_audit"] = output.slice("clauses", "missed").merge("candidate_sha" => candidate, "inputs" => ["triage_brief"])
          ac_audit_contract.validate_shape!(content, clause_ids: clause_ids, candidate_sha: candidate)
        end
        content["spec_audit"], content["mutation_proofs"] = audit_specs(candidate)
        content["regression"] = regression(candidate) if regression_spec_written?(candidate)
        contract_rejection(content, audit)
      end

      # A reproduced bug owes a regression spec the candidate adds or changes. Without one there is no run to
      # record, so the contract sends VERIFY red for BUILD to write it.
      def regression_spec_written?(candidate)
        report = artifact("repro_report")
        return false unless report["status"] == "reproduced"
        @git.call(worktree, "diff", "--name-only", "--diff-filter=AMR", base_sha, candidate).lines.map(&:strip).include?(report.fetch("rerun"))
      end

      def contract_rejection(content, audit)
        @run.coordinator.validate_verification!(content, worktree: worktree)
        "Acceptance criteria remain unverifiable" if audit["clauses"].any? { |row| row["verdict"] == "unverifiable" }
      rescue PrGraph::ContractError => error
        error.message
      end

      def spec_command(ref)
        path, line = ref.split(":", 2)
        raise Error, "spec_command must be configured to run changed specs" if @run.config["spec_command"].empty?
        @run.config["spec_command"].map { |arg| arg.gsub("{spec}", path).gsub("{line}", line.to_s) }
      end

      # The spec audit section, and beside it the full command results: the shared contract consumes its fixed
      # fields, so those results are not reported as model-authored mutation verdicts.
      def audit_specs(candidate)
        section = {"candidate_sha" => candidate, "base_sha" => base_sha, "specs" => []}
        paths = PrGraph::SpecAuditContract.changed_spec_paths(worktree, base_sha, candidate)
        return section, [] if paths.empty?
        proofs = []
        ask("spec_audit", {"test_plan" => artifact("test_plan"), "diff" => @git.diff(worktree, base_sha), "changed_specs" => paths}) do |output|
          specs = output.fetch("specs")
          proofs = mutation_proofs(specs, candidate, paths)
          audited = specs.zip(proofs).map do |spec, proof|
            spec.slice("ref", "behavior", "classes").merge("mutation" => {"change" => spec.fetch("patch"), "result" => proof["exit_code"].zero? ? "pass" : "fail"})
          end
          section = section.merge("specs" => audited)
          spec_audit_contract.validate_shape!({"spec_audit" => section}, candidate_sha: candidate, base_sha: base_sha, spec_paths: paths)
        end
        [section, proofs]
      end

      def mutation_proofs(specs, candidate, paths)
        baselines = {}
        @git.at_commit(worktree, candidate) do |tree|
          specs.map do |spec|
            mutation_proof(spec, tree, paths, baselines).tap do
              @git.call(tree, "reset", "--hard", candidate)
              @git.call(tree, "clean", "-fdxq")
            end
          end
        end
      end

      def mutation_proof(spec, tree, paths, baselines)
        path, line = spec.fetch("ref").split(":", 2)
        raise InvalidOutput, "spec audit must cite a real changed spec and line: #{spec['ref']}" unless paths.include?(path) && line.to_s.match?(/\A[1-9][0-9]*\z/) && line.to_i <= File.readlines(safe_file(worktree, path)).length
        command = spec_command(spec["ref"])
        baseline = baselines[command] ||= @checks.run(worktree, [command]).first
        raise InvalidOutput, "spec audit baseline failed: #{spec['ref']}" unless baseline["exit_code"].zero?
        @git.apply(tree, spec.fetch("patch"))
        changed = @git.changed_paths(tree, ignored: true)
        raise InvalidOutput, "mutation changed nothing: #{spec['ref']}" if changed.empty?
        outside = changed.reject { |name| production_source?(name) }
        raise InvalidOutput, "mutation must change production source only: #{outside.join(', ')}" if outside.any?
        @checks.run(tree, [command]).first
      end

      def production_source?(path)
        path.match?(SOURCE_FILE) && !path.start_with?(".") && !path.match?(TEST_TREE) && !PrGraph::SpecAuditContract.spec_path?(path)
      end

      def regression(candidate)
        path = artifact("repro_report").fetch("rerun")
        source = File.binread(safe_file(worktree, path))
        fixed = @checks.run(worktree, [spec_command(path)]).first
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

      def safe_file(root, relative, existing: true)
        root = File.realpath(root)
        inside = "#{root}/"
        raise Error, "invalid relative proof path" if relative.start_with?("/", "-") || relative.split("/").any? { |part| %w[. .. .git].include?(part) }
        target = File.expand_path(relative, root)
        raise Error, "proof path escapes its worktree" unless target.start_with?(inside)
        if existing
          raise Error, "proof file is missing or a symlink" unless File.file?(target) && !File.symlink?(target) && File.realpath(target).start_with?(inside)
        else
          parent = File.dirname(target)
          parent = File.dirname(parent) until File.exist?(parent)
          real_parent = File.realpath(parent)
          raise Error, "proof path follows a symlink outside the worktree" unless real_parent == root || real_parent.start_with?(inside)
          raise Error, "proof target is a symlink" if File.symlink?(target)
        end
        target
      end
    end
  end
end
