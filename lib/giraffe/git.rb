# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "command"
require_relative "git/checkouts"

module Giraffe
  class Git
    # For output only the harness reads, which grows with the repository rather than with anything a person wrote.
    BOOKKEEPING_LIMIT = 256_000_000

    def initialize(command: Command.new)
      @command = command
      @checkouts = Checkouts.new(git: self, command: command)
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

    # Checkouts run the project's own hooks, so one class holds how they are made and how they are removed.
    def worktree(**options) = @checkouts.worktree(**options)
    def at_commit(repo, sha, &block) = @checkouts.at_commit(repo, sha, &block)

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

    def changed_file_states(repo)
      changed_paths(repo).to_h { |path| [path, file_state(File.join(repo, path))] }
    end

    private

    def file_state(path)
      stat = File.lstat(path)
      content = if stat.symlink?
                  File.readlink(path)
                elsif stat.file?
                  Digest::SHA256.file(path).hexdigest
                end
      [stat.ftype, stat.mode, content]
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    # A hunk that ends on its changed line is taken to end the file unless told otherwise, and a model writes those.
    def run_patch(repo, patch, *options)
      result = @command.capture(["git", "apply", "--unidiff-zero", *options, "-"], cwd: repo, input: patch)
      raise PatchRejected, "patch does not apply: #{result['stderr'].lines.first.to_s.strip}" unless result["status"].zero?
      result["stdout"]
    end

    def run_git(repo, *args, limit: BOOKKEEPING_LIMIT, **options) = @command.run!(["git", *args], cwd: repo, limit: limit, **options)
    def exit_status(repo, *args) = @command.capture(["git", *args], cwd: repo)["status"]
  end
end
