# frozen_string_literal: true

require_relative "errors"
require_relative "../../scripts/spec_audit_contract"

module Giraffe
  # Proves mutations in one disposable checkout of the candidate. Every run starts from a clean copy, so a spec
  # counts as catching a mutation only when the same command passed in the same place without it.
  class MutationRunner
    def initialize(git:, checks:, tree:, candidate:)
      @git, @checks, @tree, @candidate = git, checks, tree, candidate
      @passed = {}
    end

    # The command's result with the patch applied. Raises InvalidOutput for a patch that is not a real mutation
    # of production source, and BaselineFailed when the command fails without one.
    def prove(patch, command)
      refuse_unless_production!(patch)
      passes_unmutated!(command)
      restore
      @git.apply(@tree, patch)
      raise InvalidOutput, "mutation changed nothing" if @git.changed_paths(@tree).empty?
      run(command)
    end

    private

    def refuse_unless_production!(patch)
      tracked = @git.call(@tree, "ls-files", "-z").split("\0")
      outside = @git.patch_paths(@tree, patch).reject { |path| tracked.include?(path) && PrGraph::SpecAuditContract.production_source?(path) }
      raise InvalidOutput, "mutation must change existing production source only: #{outside.join(', ')}" if outside.any?
    end

    def passes_unmutated!(command)
      return if @passed[command]
      restore
      result = run(command)
      unless result["exit_code"].zero?
        raise BaselineFailed, "#{command.join(' ')} fails from a clean checkout with no mutation applied (exit #{result['exit_code']}): #{result['excerpt'].split.last(40).join(' ')}"
      end
      @passed[command] = true
    end

    def restore
      @git.call(@tree, "reset", "--hard", @candidate)
      @git.call(@tree, "clean", "-fdxq")
    end

    def run(command) = @checks.run(@tree, [command]).first
  end
end
