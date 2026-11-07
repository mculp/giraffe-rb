# frozen_string_literal: true

require_relative "build/batch"
require_relative "build/rounds"
require_relative "build/still_red"

module Giraffe
  module Steps
    # BUILD: the writer's edits as commits, then rounds of review until a candidate passes. A candidate whose review
    # was saved before a crash is not reviewed again, only checked and handed on.
    class Build
      def call(context)
        @context = context
        git.clean!(worktree)
        saved = context.attempted_artifact("self_review")
        saved ? resume(saved) : build
      end

      private

      attr_reader :context

      def git = context.git
      def worktree = context.worktree

      def build
        plan = context.artifact("implementation_plan")
        units = plan.fetch("steps")
        write_batches(plan, units)
        conclude(Rounds.new(context, plan).call, units)
      end

      def write_batches(plan, units)
        feedback = context.runtime["verification_feedback"]
        return fix_verification(plan, feedback) if feedback
        units.each { |unit| Batch.new(context, unit.fetch("id"), {"assignment" => unit}).call }
      end

      # A red edge from VERIFY is one fix batch; the plan's units are already committed.
      def fix_verification(plan, feedback)
        Batch.new(context, "verification-fix", {"plan" => plan, "verification_feedback" => feedback}).call
        StillRed.new(context, feedback).call
      end

      def conclude(reviewed, units)
        raise Error, "BUILD produced no change from the base" if reviewed.candidate == context.base_sha
        # Save the completed review first so recovery can reuse its full history without another model call.
        context.put("self_review", reviewed.self_review, candidate: reviewed.candidate, perspective: "independent_review", covered: context.clause_ids)
        put_manifest(reviewed.candidate, units, reviewed.checks)
        context.finish
      end

      def resume(review)
        candidate = review.fetch("candidate_sha")
        raise Error, "saved BUILD review belongs to a different candidate" unless git.head(worktree) == candidate
        put_missing_manifest(candidate) unless context.attempted_artifact("build_manifest")
        context.finish
      end

      def put_missing_manifest(candidate)
        checks = context.read_only_checks
        raise Error, "saved BUILD candidate no longer passes checks" unless checks.all? { |check| check["exit_code"].zero? }
        put_manifest(candidate, context.artifact("implementation_plan").fetch("steps"), checks)
      end

      def put_manifest(candidate, units, checks)
        context.put("build_manifest", {"candidate_sha" => candidate, "base_sha" => context.base_sha,
                                       "steps" => units.map { |unit| unit["id"] }, "checks" => checks}, candidate: candidate, covered: context.clause_ids)
      end
    end
  end
end
