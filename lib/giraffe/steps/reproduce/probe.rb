# frozen_string_literal: true

require "fileutils"
require "rbconfig"

module Giraffe
  module Steps
    class Reproduce
      # Models write a probe outside the repository. Its bytes are persisted so resuming does not require the
      # old process or a session transcript, and it runs in a disposable checkout so it cannot touch the worktree.
      class Probe
        def initialize(git:, checks:, directory:)
          @git, @checks, @directory = git, checks, directory
        end

        # Runs the source in a disposable checkout of `sha`, taken from `repo`, and returns the check's result: its command,
        # exit code and excerpt.
        def run(source, repo:, sha:)
          path = store(source)
          @git.at_commit(repo, sha) { |tree| @checks.run(tree, [[RbConfig.ruby, path]]).first }
        end

        private

        def store(source)
          FileUtils.mkdir_p(@directory, mode: 0o700)
          File.join(@directory, "probe.rb").tap { |path| File.write(path, source, mode: "w", perm: 0o600) }
        end
      end
    end
  end
end
