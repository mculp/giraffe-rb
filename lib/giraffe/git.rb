# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "command"

module Giraffe
  class Git
    def initialize(command: Command.new)
      @command = command
    end

    def call(repo, *args) = run_git(repo, *args, timeout: 120).strip

    def clean!(repo)
      raise Error, "worktree is dirty; inspect or restore interrupted work before resuming: #{repo}" unless call(repo, "status", "--porcelain=v1", "--untracked-files=all").empty?
    end

    def head(repo) = call(repo, "rev-parse", "HEAD")
    def resolve_commit(repo, ref) = call(repo, "rev-parse", "--verify", "#{ref}^{commit}")

    def fingerprint(repo)
      {"head" => head(repo), "branch" => call(repo, "symbolic-ref", "--quiet", "--short", "HEAD"),
       "common_git_dir" => common(repo), "origin" => call(repo, "remote", "get-url", "origin"),
       "push_origin" => call(repo, "remote", "get-url", "--push", "origin"),
       "status" => call(repo, "status", "--porcelain=v1", "--untracked-files=all"),
       "diff" => Digest::SHA256.hexdigest(call(repo, "diff", "--binary", "HEAD", "--")),
       "index" => Digest::SHA256.hexdigest(call(repo, "ls-files", "--stage"))}
    end

    def unchanged!(repo, before)
      raise Error, "read-only step changed the candidate or working tree" unless fingerprint(repo) == before
    end

    # The block's value, once it is known not to have changed the candidate or working tree.
    def read_only(repo)
      before = fingerprint(repo)
      yield.tap { unchanged!(repo, before) }
    end

    def worktree(repo:, path:, branch:, base:)
      call(repo, "check-ref-format", "--branch", branch)
      base_sha = resolve_commit(repo, base)
      if File.exist?(path)
        raise Error, "unexpected existing worktree path: #{path}" unless File.directory?(path) && File.realpath(call(path, "rev-parse", "--show-toplevel")) == File.realpath(path)
        raise Error, "worktree belongs to another branch" unless call(path, "branch", "--show-current") == branch
        raise Error, "worktree belongs to another repository" unless common(path) == common(repo)
        clean!(path)
      else
        # Never adopt an unrelated pre-existing branch implicitly.
        raise Error, "branch already exists outside this run: #{branch}" if exit_status(repo, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}").zero?
        FileUtils.mkdir_p(File.dirname(path))
        call(repo, "worktree", "add", "-b", branch, path, base_sha)
      end
      {"path" => File.realpath(path), "branch" => branch, "base_sha" => base_sha, "common_git_dir" => common(repo)}
    end

    def common(repo)
      File.realpath(File.expand_path(call(repo, "rev-parse", "--git-common-dir"), repo))
    end

    def commit(repo, message)
      call(repo, "add", "-A", "--", ".")
      staged = exit_status(repo, "diff", "--cached", "--quiet")
      return nil if staged.zero?
      raise Error, "could not inspect staged change" unless staged == 1
      call(repo, "-c", "core.hooksPath=/dev/null", "commit", "-m", message)
      clean!(repo)
      head(repo)
    end

    def diff(repo, base) = run_git(repo, "diff", "--binary", "#{base}...HEAD", "--", timeout: 120)

    # All or nothing: a patch that does not apply raises and leaves the tree alone.
    def apply(repo, patch)
      result = @command.capture(["git", "apply", "-"], cwd: repo, input: patch)
      raise PatchRejected, "patch does not apply: #{result['stderr'].lines.first.to_s.strip}" unless result["status"].zero?
    end

    # `ignored` also counts gitignored files, which a patch can create though status normally hides them.
    def changed_paths(repo, ignored: false)
      raw = run_git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", *("--ignored" if ignored))
      entries = raw.split("\0")
      paths = []
      until entries.empty?
        entry = entries.shift
        paths << entry[3..]
        paths << entries.shift if entry[0, 2].match?(/[RC]/)
      end
      paths.compact
    end

    def at_commit(repo, sha)
      Dir.mktmpdir("giraffe-proof-") do |directory|
        target = File.join(directory, "tree")
        call(repo, "worktree", "add", "--detach", target, sha)
        begin
          yield target
        ensure
          call(repo, "worktree", "remove", "--force", target)
        end
      end
    end

    private

    def run_git(repo, *args, **options) = @command.run!(["git", *args], cwd: repo, **options)
    def exit_status(repo, *args) = @command.capture(["git", *args], cwd: repo)["status"]
  end
end
