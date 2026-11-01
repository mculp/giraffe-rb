# frozen_string_literal: true

module Giraffe
  module Steps
    module Build
      def step_build
        @git.clean!(worktree)
        if attempted_artifact("build_manifest") && attempted_artifact("self_review")
          finish
          return
        end
        units = artifact("implementation_plan").fetch("steps")
        units.each { |unit| write_batch(unit.fetch("id"), {"assignment" => unit, "verification_feedback" => runtime["verification_feedback"]}) }
        reviews = []
        @run.config["max_fix_rounds"].times do |round|
          checks = build_checks
          review = ask("review", {"ticket" => @run.state["ticket"], "plan" => artifact("implementation_plan"),
                                  "diff" => @git.diff(worktree, base_sha), "checks" => checks}, unit: "review-#{round}")
          reviews << review
          blocking = review.fetch("findings").select { |finding| finding["severity"] == "blocking" }
          if blocking.empty? && checks.all? { |check| check["exit_code"].zero? }
            candidate = @git.head(worktree)
            raise Error, "BUILD produced no change from the base" if candidate == base_sha
            put("build_manifest", {"candidate_sha" => candidate, "base_sha" => base_sha,
                                   "steps" => units.map { |unit| unit["id"] }, "checks" => checks}, candidate: candidate, covered: clause_ids)
            put("self_review", {"candidate_sha" => candidate, "reviews" => reviews}, candidate: candidate,
                perspective: "independent_review", covered: clause_ids)
            finish
            return
          end
          write_batch("fix-#{round}", {"findings" => blocking, "failed_checks" => checks.reject { |check| check["exit_code"].zero? }})
        end
        raise Error, "BUILD reached its fix-round limit; the writer remains open for inspection"
      end

      def write_batch(unit, assignment)
        key = "build:#{@attempt}:#{unit}"
        return if runtime.fetch("build_commits", {}).key?(key)
        trailer = "Giraffe-Unit: #{key}"
        recovered = @git.call(worktree, "log", "--format=%H", "--fixed-strings", "--grep=#{trailer}", "#{base_sha}..HEAD").lines.map(&:strip)
        if recovered.any?
          raise Error, "ambiguous recovered BUILD commit" unless recovered.one?
          checkpoint("build_commits", runtime.fetch("build_commits", {}).merge(key => recovered.first))
          return
        end
        @git.clean!(worktree)
        ask("build", assignment.merge("ticket" => @run.state["ticket"], "test_plan" => artifact("test_plan"),
                                      "reproduction" => runtime["reproduction"], "answers" => @run.state["answers"]), writable: true, unit: unit)
        guard_changed_paths!
        # Autocorrect belongs to BUILD; VERIFY runs it read-only and refuses any resulting mutation.
        @checks.run(worktree, @run.config["lint"])
        guard_changed_paths!
        sha = @git.commit(worktree, "#{@run.state.dig('ticket', 'title')}\n\n#{trailer}") || @git.head(worktree)
        checkpoint("build_commits", runtime.fetch("build_commits", {}).merge(key => sha))
      end

      def guard_changed_paths!
        paths = @git.changed_paths(worktree)
        forbidden = paths.select { |path| path.match?(%r{(^|/)(\.git|\.claude|\.cursor|\.giraffe|\.env(?:\..*)?|credentials)(/|$)|(^|/)(CLAUDE|AGENTS)\.md$|\.(pem|key)$}) }
        raise Error, "BUILD changed protected files: #{forbidden.join(', ')}" if forbidden.any?
      end

      def build_checks
        before = @git.fingerprint(worktree)
        results = @checks.run(worktree)
        @git.unchanged!(worktree, before)
        results
      end
    end
  end
end
