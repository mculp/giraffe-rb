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

    def fingerprint(repo) = identity(repo).merge(working_tree(repo))

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
      return unless staged_change?(repo)
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
      entries = run_git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all").split("\0")
      paths = []
      paths.concat(take_paths(entries)) until entries.empty?
      paths.compact
    end

    def changed_file_states(repo)
      changed_paths(repo).to_h { |path| [path, file_state(File.join(repo, path))] }
    end

    private

    # What a writer may not change, unlike its working tree: Model::IDENTITY names these keys.
    def identity(repo)
      {"head" => head(repo), "branch" => call(repo, "symbolic-ref", "--quiet", "--short", "HEAD"), "common_git_dir" => common(repo),
       "origin" => call(repo, "remote", "get-url", "origin"), "push_origin" => call(repo, "remote", "get-url", "--push", "origin")}
    end

    def working_tree(repo)
      {"status" => call(repo, "status", "--porcelain=v1", "--untracked-files=all"),
       "diff" => Digest::SHA256.hexdigest(call(repo, "diff", "--binary", "HEAD", "--")),
       "index" => Digest::SHA256.hexdigest(call(repo, "ls-files", "--stage"))}
    end

    # Exit status 1 says there is something staged, and 0 that there is not. Anything else is git failing to say.
    def staged_change?(repo)
      staged = exit_status(repo, "diff", "--cached", "--quiet")
      raise Error, "could not inspect staged change" unless [0, 1].include?(staged)
      staged == 1
    end

    # Takes the next entry off the list. A rename or copy is followed by an entry of its own for the path it came from.
    def take_paths(entries)
      entry = entries.shift
      entry[0, 2].match?(/[RC]/) ? [entry[3..], entries.shift] : [entry[3..]]
    end

    def file_state(path)
      stat = File.lstat(path)
      [stat.ftype, stat.mode, content_of(path, stat)]
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    # Where a link points, and what a regular file holds. There is nothing to say about anything else.
    def content_of(path, stat)
      return File.readlink(path) if stat.symlink?
      Digest::SHA256.file(path).hexdigest if stat.file?
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
