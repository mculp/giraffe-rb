# frozen_string_literal: true

require_relative "../../mutation_runner"
require_relative "../../../../scripts/spec_audit_contract"
require_relative "mutation_proofs"
require_relative "spec_command"

module Giraffe
  module Steps
    module Verify
      # The model's audit of the specs a candidate adds or changes, with each mutation it proposes proved by running it.
      class SpecAudit
        def initialize(context, candidate)
          @context, @candidate = context, candidate
        end

        # The spec audit section, and beside it the full command results: the shared contract consumes its fixed
        # fields, so those results are not reported as model-authored mutation verdicts.
        def call
          section = {"candidate_sha" => @candidate, "base_sha" => @context.base_sha, "specs" => []}
          return section, [] if paths.empty?
          @context.ask("spec_audit", inputs) { |output| accept(section, output.fetch("specs")) }
        end

        private

        def paths = @paths ||= PrGraph::SpecAuditContract.changed_spec_paths(@context.worktree, @context.base_sha, @candidate)

        def inputs
          {"test_plan" => @context.artifact("test_plan"), "diff" => @context.git.diff(@context.worktree, @context.base_sha), "changed_specs" => paths}
        end

        # Inside the model call, so that a spec the audit cannot stand behind is refused and asked again.
        def accept(section, specs)
          proofs = prove(specs)
          audit = section.merge("specs" => specs.zip(proofs).map { |spec, proof| audited(spec, proof) })
          @context.spec_audit_contract.validate_shape!({"spec_audit" => audit}, candidate_sha: @candidate, base_sha: @context.base_sha, spec_paths: paths)
          [audit, proofs]
        end

        # What the audit records of a spec: a mutation it still passes under is one it did not catch.
        def audited(spec, proof)
          spec.slice("ref", "behavior", "classes").merge("mutation" => {"change" => spec.fetch("patch"), "result" => proof["exit_code"].zero? ? "pass" : "fail"})
        end

        def prove(specs)
          MutationProofs.new(runner: runner, worktree: @context.worktree, paths: paths, spec_command: spec_command).call(specs)
        end

        def runner = MutationRunner.new(git: @context.git, checks: @context.checks, worktree: @context.worktree, candidate: @candidate)

        # The context has no reader for the configuration, so it comes from the run, as the mixins read it.
        def spec_command = SpecCommand.new(@context.run.config["spec_command"])
      end
    end
  end
end
