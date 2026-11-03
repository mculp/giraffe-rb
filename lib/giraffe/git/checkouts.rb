# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../command"

module Giraffe
  class Git
    # The checkouts a run works in: its own worktree, and a short-lived one for each proof. Making one runs the project's
    # post-checkout hook, which is why a checkout is made with time and a bare environment, and why one that failed, or
    # was only half made, is removed instead of trusted.
    class Checkouts
      # A post-checkout hook may well install dependencies.
      TIMEOUT = 600

      # The Git this belongs to answers questions about the repository. The command is the one that Git runs git with,
      # so a checkout stays inside the same limits, and is cancelled with the run.
      def initialize(git:, command:)
        @git, @command = git, command
      end

      def worktree(repo:, path:, branch:, base:)
        @git.call(repo, "check-ref-format", "--branch", branch)
        base_sha = @git.resolve_commit(repo, base)
        discard_unfinished(repo, path, branch) if File.exist?(path)
        create(repo, path, branch, base_sha)
        {"path" => File.realpath(path), "branch" => branch, "base_sha" => base_sha, "common_git_dir" => @git.common(repo)}
      end

      def at_commit(repo, sha, &block)
        Dir.mktmpdir("giraffe-proof-") { |directory| checked_out(repo, File.join(directory, "tree"), sha, &block) }
      end

      private

      # Never adopt an unrelated pre-existing branch implicitly.
      def create(repo, path, branch, base_sha)
        raise Error, "branch already exists outside this run: #{branch}" if branch?(repo, branch)
        FileUtils.mkdir_p(File.dirname(path))
        add(repo, "-b", branch, path, base_sha)
      end

      # Whatever the block or the checkout's hook did, nothing stays registered with the repository.
      def checked_out(repo, target, sha)
        add(repo, "--detach", target, sha)
        yield target
      ensure
        remove(repo, target) if File.exist?(target)
      end

      # A worktree found here never finished being made: its hook failed, or died with the machine, so it lacks what
      # the hook provides. Nothing leads back to WORKTREE once it finishes, so nothing has worked in this one.
      def discard_unfinished(repo, path, branch)
        raise Error, "unexpected existing worktree path: #{path}" unless File.directory?(path) && File.realpath(@git.call(path, "rev-parse", "--show-toplevel")) == File.realpath(path)
        raise Error, "worktree belongs to another branch" unless @git.call(path, "branch", "--show-current") == branch
        raise Error, "worktree belongs to another repository" unless @git.common(path) == @git.common(repo)
        remove(repo, path)
        @git.call(repo, "branch", "-D", branch)
      end

      def branch?(repo, branch) = @command.capture(["git", "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], cwd: repo)["status"].zero?

      # Checking out runs the project's post-checkout hook on the commit's files, outside the checks' sandbox. It gets
      # time to install what it must, and no more of the harness's environment than a check gets.
      def add(repo, *args)
        @command.run!(["git", "worktree", "add", *args], cwd: repo, limit: BOOKKEEPING_LIMIT, timeout: TIMEOUT, env: ENV.slice(*Command::PROJECT_ENV), clean_env: true)
      end

      # Writable first: a spec or hook can leave a directory read-only, which nothing could then empty. Twice forced,
      # because git leaves a worktree it died making locked.
      def remove(repo, path)
        FileUtils.chmod_R("u+w", path, force: true)
        @git.call(repo, "worktree", "remove", "--force", "--force", path)
      end
    end
  end
end
