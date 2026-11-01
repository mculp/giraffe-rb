# frozen_string_literal: true

module Giraffe
  module Steps
    module Build
      PROTECTED = %r{(^|/)(\.git|\.claude|\.cursor|\.giraffe|\.husky|\.env(?:\..*)?|credentials)(/|$)|(^|/)(CLAUDE|AGENTS)\.md$|\.(pem|key)$}

      def step_build
        @git.clean!(worktree)
        if (saved_review = attempted_artifact("self_review"))
          return resume_reviewed_build(saved_review)
        end

        plan = artifact("implementation_plan")
        units = plan.fetch("steps")
        if (feedback = runtime["verification_feedback"])
          # A red edge from VERIFY is one fix batch; the plan's units are already committed.
          write_batch("verification-fix", {"plan" => plan, "verification_feedback" => feedback})
          ask_a_person_if_unchanged(feedback)
        else
          units.each { |unit| write_batch(unit.fetch("id"), {"assignment" => unit}) }
        end
        reviews = []
        checks = review = candidate = nil
        @run.config["max_fix_rounds"].times do |round|
          head = @git.head(worktree)
          # A fix that changed nothing, or a resume past recorded fixes, leaves nothing new to check or review.
          unless head == candidate
            candidate = head
            checks = read_only_checks
            review = ask("review", {"plan" => plan, "diff" => @git.diff(worktree, base_sha), "checks" => checks}, unit: "review-#{round}")
            reviews << review
          end
          blocking = review.fetch("findings").select { |finding| finding["severity"] == "blocking" }
          if blocking.empty? && checks.all? { |check| check["exit_code"].zero? }
            raise Error, "BUILD produced no change from the base" if candidate == base_sha
            # Save the completed review first so recovery can reuse its full history without another model call.
            put("self_review", {"candidate_sha" => candidate, "reviews" => reviews}, candidate: candidate,
                perspective: "independent_review", covered: clause_ids)
            put_build_manifest(candidate, units, checks)
            finish
            return
          end
          write_batch("fix-#{round}", {"findings" => blocking, "failed_checks" => checks.reject { |check| check["exit_code"].zero? }})
        end
        raise Error, "BUILD reached its fix-round limit; the writer remains open for inspection"
      end

      def resume_reviewed_build(review)
        candidate = review.fetch("candidate_sha")
        raise Error, "saved BUILD review belongs to a different candidate" unless @git.head(worktree) == candidate

        unless attempted_artifact("build_manifest")
          checks = read_only_checks
          raise Error, "saved BUILD candidate no longer passes checks" unless checks.all? { |check| check["exit_code"].zero? }
          put_build_manifest(candidate, artifact("implementation_plan").fetch("steps"), checks)
        end
        finish
      end

      # The same candidate can only come back red, so what BUILD has no edit for is a person's to settle, unless one
      # has answered since that red, whether this question or one BUILD asked for itself.
      def ask_a_person_if_unchanged(feedback)
        return unless @git.head(worktree) == feedback.fetch("candidate_sha") && @run.state["answers"].size == feedback["answers_seen"]
        open_clauses = feedback.dig("ac_audit", "clauses").to_a.reject { |row| row["verdict"] == "met" }
        details = open_clauses.map { |row| "#{row['clause_id']}: #{row['reason']}" }.join(" ")
        text = "VERIFY stays red and BUILD found no edit to make: #{feedback.fetch('reason')}. #{details} " \
               "Please answer with evidence, such as what a command printed on #{feedback.fetch('candidate_sha')}, or with what should change."
        @run.update(status: "waiting_for_answers", questions: [{"id" => "verification-#{@attempt}", "text" => text, "role" => "build", "attempt_id" => @attempt}])
        raise Parked, "waiting for a person's answer"
      end

      def put_build_manifest(candidate, units, checks)
        put("build_manifest", {"candidate_sha" => candidate, "base_sha" => base_sha,
                               "steps" => units.map { |unit| unit["id"] }, "checks" => checks}, candidate: candidate, covered: clause_ids)
      end

      def write_batch(unit, assignment)
        key = "build:#{@attempt}:#{unit}"
        return if runtime.fetch("build_commits", {}).key?(key)
        trailer = "Giraffe-Unit: #{key}"
        recovered = @git.call(worktree, "log", "--format=%H", "--fixed-strings", "--grep=#{trailer}", "#{base_sha}..HEAD").lines.map(&:strip)
        if recovered.any?
          raise Error, "ambiguous recovered BUILD commit" unless recovered.one?
          @run.checkpoint_entry("build_commits", key, recovered.first)
          return
        end
        @git.clean!(worktree)
        ask("build", assignment.merge("test_plan" => artifact("test_plan"), "reproduction" => runtime["reproduction"]), writable: true, unit: unit)
        guard_changed_paths!
        # Autocorrect belongs to BUILD; VERIFY runs it read-only and refuses any resulting mutation.
        @checks.run(worktree, @run.config["lint"])
        guard_changed_paths!
        sha = @git.commit(worktree, "#{@run.state.dig('ticket', 'title')}\n\n#{trailer}") || @git.head(worktree)
        @run.checkpoint_entry("build_commits", key, sha)
      end

      def guard_changed_paths!
        hooks = @git.hooks_prefix(worktree)
        forbidden = @git.changed_paths(worktree).select { |path| path.match?(PROTECTED) || (hooks && path.start_with?(hooks)) }
        raise Error, "BUILD changed protected files: #{forbidden.join(', ')}" if forbidden.any?
      end
    end
  end
end
