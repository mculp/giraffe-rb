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
        before = @git.fingerprint(worktree)
        checks = @checks.run(worktree, @run.config["checks"] + @run.config["lint"])
        @git.unchanged!(worktree, before)
        content = {"candidate_sha" => candidate, "checks" => checks}
        reason = nil
        if checks.any? { |check| !check["exit_code"].zero? }
          reason = "Executable verification failed"
        else
          # Deliberately exclude the implementation and test plans from the acceptance call.
          audit = ask("audit", {"ticket" => @run.state["ticket"], "triage_brief" => artifact("triage_brief"),
                               "diff" => @git.diff(worktree, base_sha), "checks" => checks})
          content["ac_audit"] = audit.slice("clauses", "missed").merge("candidate_sha" => candidate, "inputs" => ["triage_brief"])
          content["spec_audit"] = audit_specs(candidate)
          content["regression"] = regression(candidate) if artifact("repro_report")["status"] == "reproduced"
          begin
            PrGraph::AcAuditContract.new.validate!(content, clause_ids: clause_ids, candidate_sha: candidate)
            specs = PrGraph::SpecAuditContract.changed_spec_paths(worktree, base_sha, candidate)
            PrGraph::SpecAuditContract.new.validate!(content, candidate_sha: candidate, base_sha: base_sha, spec_paths: specs)
            PrGraph::ReproContract.new.validate_regression!(artifact("repro_report"), content, candidate_sha: candidate,
              changed_paths: @git.call(worktree, "diff", "--name-only", base_sha, candidate).lines.map(&:strip))
            unverifiable = audit["clauses"].select { |row| row["verdict"] == "unverifiable" }
            raise Error, "Acceptance criteria remain unverifiable" if unverifiable.any?
          rescue PrGraph::ContractError, Error => error
            reason = error.message
          end
        end
        @git.unchanged!(worktree, before)
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

      def spec_command(ref)
        path, line = ref.split(":", 2)
        raise Error, "spec_command must be configured to run changed specs" if @run.config["spec_command"].empty?
        @run.config["spec_command"].map { |arg| arg.gsub("{spec}", path).gsub("{line}", line.to_s) }
      end

      def audit_specs(candidate)
        paths = PrGraph::SpecAuditContract.changed_spec_paths(worktree, base_sha, candidate)
        return {"candidate_sha" => candidate, "base_sha" => base_sha, "specs" => []} if paths.empty?
        output = ask("spec_audit", {"ticket" => @run.state["ticket"], "test_plan" => artifact("test_plan"),
                                   "diff" => @git.diff(worktree, base_sha), "changed_specs" => paths})
        specs = output.fetch("specs").map do |spec|
          path, line = spec.fetch("ref").split(":", 2)
          raise Error, "spec audit must cite a real changed spec and line" unless paths.include?(path) && line.to_s.match?(/\A[1-9][0-9]*\z/) && line.to_i <= File.readlines(safe_file(worktree, path)).length
          baseline = @checks.run(worktree, [spec_command(spec["ref"])]).first
          raise Error, "spec audit baseline failed" unless baseline["exit_code"].zero?
          proof = @git.at_commit(worktree, candidate) do |tree|
            @command.run!(["git", "-C", tree, "apply", "--check", "-"], cwd: tree, input: spec.fetch("patch"))
            @command.run!(["git", "-C", tree, "apply", "-"], cwd: tree, input: spec.fetch("patch"))
            changed = @git.call(tree, "diff", "--name-only").lines.map(&:strip)
            if changed.empty? || changed.any? { |name| PrGraph::SpecAuditContract.spec_path?(name) || name.start_with?(".") || !name.match?(/\.(rb|[jt]sx?|py|go|rs|java|ex|exs)\z/) }
              raise Error, "mutation must change production source only"
            end
            @checks.run(tree, [spec_command(spec["ref"])]).first
          end
          spec.slice("ref", "behavior", "classes").merge("mutation" => {
            "change" => spec.fetch("patch"), "result" => proof["exit_code"].zero? ? "pass" : "fail"}, "proof" => proof)
        end
        # The shared contract consumes its fixed fields. Full command results stay in a separate
        # verification section, rather than being reported as model-authored mutation verdicts.
        checkpoint("mutation_proof:#{@attempt}", specs.map { |spec| spec["proof"] })
        {"candidate_sha" => candidate, "base_sha" => base_sha, "specs" => specs.map { |spec| spec.reject { |key, _| key == "proof" } }}
      end

      def regression(candidate)
        path = runtime.fetch("reproduction").fetch("regression_spec")
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
        raise Error, "invalid relative proof path" if relative.start_with?("/", "-") || relative.split("/").any? { |part| %w[. .. .git].include?(part) }
        target = File.expand_path(relative, root)
        raise Error, "proof path escapes its worktree" unless target.start_with?(File.realpath(root) + "/")
        if existing
          raise Error, "proof file is missing or a symlink" unless File.file?(target) && !File.symlink?(target) && File.realpath(target).start_with?(File.realpath(root) + "/")
        else
          parent = File.dirname(target)
          parent = File.dirname(parent) until File.exist?(parent)
          raise Error, "proof path follows a symlink outside the worktree" unless File.realpath(parent) == File.realpath(root) || File.realpath(parent).start_with?(File.realpath(root) + "/")
          raise Error, "proof target is a symlink" if File.symlink?(target)
        end
        target
      end
    end
  end
end
