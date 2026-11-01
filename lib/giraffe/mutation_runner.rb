# frozen_string_literal: true

require_relative "command"
require_relative "errors"
require_relative "../../scripts/spec_audit_contract"

module Giraffe
  # Proves mutations of one candidate. Every run gets its own checkout, so nothing a run leaves behind reaches the
  # next, and a spec counts as catching a mutation only when the same command passed without it.
  class MutationRunner
    def initialize(git:, checks:, worktree:, candidate:, production: PrGraph::SpecAuditContract.method(:production_source?))
      @git, @checks, @worktree, @candidate, @production = git, checks, worktree, candidate, production
      @passed = {}
    end

    # The command's result with the patch applied. Raises InvalidOutput for a patch that is not a real mutation
    # of production source, and BaselineFailed when the command fails without one.
    def prove(patch, command)
      refuse_new_files!(patch)
      @passed[command] ||= passes_unmutated!(command)
      @git.at_commit(@worktree, @candidate) do |tree|
        apply_mutation(tree, patch)
        run(tree, command)
      end
    end

    private

    # Only the patch can say: a new file somewhere ignored would not show in the applied tree.
    def refuse_new_files!(patch) = refuse!(@git.patch_paths(@worktree, patch) - @git.tracked_paths(@worktree))

    # Compare file states so a patch cannot hide another edit behind a hook's existing change.
    # Keep paths that disappeared from status too: the patch may have restored a hook's output to HEAD.
    def apply_mutation(tree, patch)
      before = @git.changed_file_states(tree)
      @git.apply(tree, patch)
      after = @git.changed_file_states(tree)
      changed = (before.keys | after.keys).select do |path|
        before.fetch(path, :unchanged) != after.fetch(path, :unchanged)
      end
      raise InvalidOutput, "mutation changed nothing" if changed.empty?
      refuse!(changed.reject(&@production))
    end

    def refuse!(outside)
      raise InvalidOutput, "mutation must change existing production source only: #{outside.join(', ')}" if outside.any?
    end

    def passes_unmutated!(command)
      result = @git.at_commit(@worktree, @candidate) { |tree| run(tree, command) }
      return true if result["exit_code"].zero?
      raise BaselineFailed, "#{command.join(' ')} fails from a clean checkout with no mutation applied " \
                            "(exit #{result['exit_code']}): #{Command.tail(result['excerpt'])}"
    end

    def run(tree, command) = @checks.run(tree, [command]).first
  end
end
