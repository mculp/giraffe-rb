# frozen_string_literal: true

require_relative "command"
require_relative "errors"

module Giraffe
  # Puts a checked commit straight on a branch, for a project that works on main without pull requests. It only ever
  # fast-forwards: the branch must already sit under the commit, so nothing that landed before is rewritten and
  # nothing is pushed with force. A commit cut from an older branch head comes back as behind, and the caller
  # rebases it, checks it again, and lands that.
  class Landing
    Result = Data.define(:status, :sha, :base_sha) do
      def landed? = status == :landed
      def behind? = status == :behind
    end
    # What git says when the branch moved under a push.
    MOVED = /non-fast-forward|fetch first|\[rejected\]|stale info/

    def initialize(command: Command.new, remote: "origin")
      @command, @remote = command, remote
    end

    def land(repo, sha:, branch: "main")
      base = fetch(repo, branch)
      return Result.new(status: :behind, sha: sha, base_sha: base) unless ancestor?(repo, base, sha)
      return Result.new(status: :landed, sha: sha, base_sha: base) if base == sha
      push(repo, sha, branch, base)
    end

    # The commits since base, replayed on the branch's newest head. A conflict leaves the tree as it was and raises.
    def rebase(repo, branch: "main")
      onto = fetch(repo, branch)
      result = git(repo, "-c", "core.hooksPath=/dev/null", "rebase", onto)
      return git!(repo, "rev-parse", "HEAD") if result["status"].zero?
      git(repo, "rebase", "--abort")
      raise Error, "rebase onto #{@remote}/#{branch} conflicts: #{Command.tail(result['stdout'] + result['stderr'])}"
    end

    private

    def fetch(repo, branch)
      git!(repo, "fetch", "--no-tags", @remote, "+refs/heads/#{branch}:refs/remotes/#{@remote}/#{branch}")
      git!(repo, "rev-parse", "--verify", "refs/remotes/#{@remote}/#{branch}^{commit}")
    end

    def ancestor?(repo, base, sha) = git(repo, "merge-base", "--is-ancestor", base, sha)["status"].zero?

    # Without hooks: a pre-push hook would run the candidate's code with the credentials a push needs. A plain push
    # is refused when the branch moved since the fetch, which comes back as behind.
    def push(repo, sha, branch, base)
      result = git(repo, "-c", "core.hooksPath=/dev/null", "push", "--porcelain", @remote, "#{sha}:refs/heads/#{branch}")
      return Result.new(status: :landed, sha: sha, base_sha: base) if result["status"].zero?
      return Result.new(status: :behind, sha: sha, base_sha: base) if (result["stdout"] + result["stderr"]).match?(MOVED)
      raise Error, "push to #{@remote}/#{branch} failed: #{Command.tail(result['stderr'])}"
    end

    def git(repo, *args) = @command.capture(["git", *args], cwd: repo, timeout: 120)
    def git!(repo, *args) = @command.run!(["git", *args], cwd: repo, timeout: 120).strip
  end
end
