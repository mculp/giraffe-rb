# frozen_string_literal: true

module Giraffe
  module Steps
    # Reads the ticket against the repository itself, before any worktree exists, so a repository holding someone's
    # unfinished work stops the run before a model is asked about it.
    class Triage
      def call(context)
        repo = context.run.config["repo"]
        context.git.clean!(repo)
        context.ask("triage", {}, cwd: repo) { |output| context.put("triage_brief", output.merge("ticket" => context.run.state["ticket"])) }
        context.finish
      end
    end
  end
end
