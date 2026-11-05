# frozen_string_literal: true

module Giraffe
  module Steps
    # Makes the run's own worktree on a branch of its own, and keeps the commit it was cut from. Every step after this one
    # measures against that commit, so a base that moves on origin meanwhile does not move it.
    class Worktree
      def call(context)
        run = context.run
        manifest = context.git.worktree(repo: run.config["repo"], path: context.worktree, branch: "codex/giraffe-#{run.id}", base: run.config["base"])
        context.checkpoint("base_sha", manifest["base_sha"])
        context.put("worktree_manifest", manifest)
        context.finish
      end
    end
  end
end
