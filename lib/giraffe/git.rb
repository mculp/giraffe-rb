# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "tmpdir"
require_relative "command"

module Giraffe
  class Git
    # For output only the harness reads, which grows with the repository rather than with anything a person wrote.
    BOOKKEEPING_LIMIT = 256_000_000
    # A post-checkout hook may well install dependencies.
    CHECKOUT_TIMEOUT = 600

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
      discard_unfinished_worktree(repo, path, branch) if File.exist?(path)
      # Never adopt an unrelated pre-existing branch implicitly.
      raise Error, "branch already exists outside this run: #{branch}" if exit_status(repo, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}").zero?
      FileUtils.mkdir_p(File.dirname(path))
      add_checkout(repo, "-b", branch, path, base_sha)
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

    # Without hooks, like a commit: a pre-push hook would run the candidate's code with the credentials a push needs.
    def push(repo, branch) = call(repo, "-c", "core.hooksPath=/dev/null", "push", "origin", "HEAD:refs/heads/#{branch}")

    # For a prompt. Past the command limit a model is better off reading the files it needs.
    def diff(repo, base)
      run_git(repo, "diff", "--binary", "#{base}...HEAD", "--", timeout: 120, limit: Command::LIMIT)
    rescue CommandLimit
      "This diff is too large to include. Read the changed files:\n" + run_git(repo, "diff", "--stat", "#{base}...HEAD", "--", timeout: 120)
    end

    # All or nothing: a patch that does not apply raises and leaves the tree alone.
    def apply(repo, patch) = run_patch(repo, patch)

    # The paths a patch touches, read from the patch itself rather than the tree it would change.
    def patch_paths(repo, patch)
      run_patch(repo, patch, "--numstat", "-z").split("\0").map { |entry| entry.split("\t", 3).last }
    end

    def ignored?(repo, path) = exit_status(repo, "check-ignore", "-q", "--", path).zero?
    def tracked_paths(repo) = call(repo, "ls-files", "-z").split("\0")

    # What a path in the tree starts with when it is a hook, if hooks are configured: where a candidate could rewrite them.
    def hooks_prefix(repo)
      path = @command.capture(["git", "config", "core.hooksPath"], cwd: repo)["stdout"].strip
      "#{Pathname.new(path).cleanpath}/" unless path.empty?
    end

    def changed_paths(repo)
      raw = run_git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all")
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
        begin
          add_checkout(repo, "--detach", target, sha)
          yield target
        ensure
          remove_checkout(repo, target) if File.exist?(target)
        end
      end
    end

    private

    # A worktree found here never finished being made: its hook failed, or died with the machine, so it lacks what
    # the hook provides. Nothing leads back to WORKTREE once it finishes, so nothing has worked in this one.
    def discard_unfinished_worktree(repo, path, branch)
      raise Error, "unexpected existing worktree path: #{path}" unless File.directory?(path) && File.realpath(call(path, "rev-parse", "--show-toplevel")) == File.realpath(path)
      raise Error, "worktree belongs to another branch" unless call(path, "branch", "--show-current") == branch
      raise Error, "worktree belongs to another repository" unless common(path) == common(repo)
      remove_checkout(repo, path)
      call(repo, "branch", "-D", branch)
    end

    # Checking out runs the project's post-checkout hook on the commit's files, outside the checks' sandbox. It gets
    # time to install what it must, and no more of the harness's environment than a check gets.
    def add_checkout(repo, *args)
      run_git(repo, "worktree", "add", *args, timeout: CHECKOUT_TIMEOUT, env: ENV.slice(*Command::PROJECT_ENV), clean_env: true)
    end

    # Writable first: a spec or hook can leave a directory read-only, which nothing could then empty. Twice forced,
    # because git leaves a worktree it died making locked.
    def remove_checkout(repo, path)
      FileUtils.chmod_R("u+w", path, force: true)
      call(repo, "worktree", "remove", "--force", "--force", path)
    end

    def run_patch(repo, patch, *options)
      result = @command.capture(["git", "apply", *options, "-"], cwd: repo, input: patch)
      raise PatchRejected, "patch does not apply: #{result['stderr'].lines.first.to_s.strip}" unless result["status"].zero?
      result["stdout"]
    end

    def run_git(repo, *args, limit: BOOKKEEPING_LIMIT, **options) = @command.run!(["git", *args], cwd: repo, limit: limit, **options)
    def exit_status(repo, *args) = @command.capture(["git", *args], cwd: repo)["status"]
  end
end
