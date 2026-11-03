# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../lib/giraffe/git"

# Pins what Giraffe::Git does through its public methods, in real temporary repositories, so the code behind them can
# be reshaped without anyone noticing. Expected values come from plain git or from the filesystem, never from Git.
class GitTest < Minitest::Test
  # Runs every command for real and remembers it. A reply the test supplies stands in for running that argv.
  class RecordingCommand < Giraffe::Command
    attr_reader :calls

    def initialize(replies = {})
      super()
      @replies, @calls = replies, []
    end

    def capture(argv, **options)
      @calls << [argv, options]
      reply = @replies[argv]
      reply ? reply.call : super
    end

    def checkouts = @calls.select { |argv, _| argv.first(3) == %w[git worktree add] }
    def removals = @calls.select { |argv, _| argv.first(3) == %w[git worktree remove] }
  end

  def setup
    @old_env = ENV.to_h
    @tmp = File.realpath(Dir.mktmpdir("giraffe-git-test-"))
    # Nobody's own git configuration reaches these repositories, and nothing a test makes escapes into the shared tmp.
    ENV["HOME"] = File.join(@tmp, "home")
    ENV["XDG_CONFIG_HOME"] = File.join(@tmp, "home/.config")
    ENV["GIT_CONFIG_NOSYSTEM"] = "1"
    ENV["TMPDIR"] = @scratch = File.join(@tmp, "scratch")
    [ENV["HOME"], @scratch].each { |directory| Dir.mkdir(directory) }
    @repo = File.join(@tmp, "app")
    @git = Giraffe::Git.new
    make_repository
  end

  def teardown
    ENV.replace(@old_env)
    FileUtils.chmod_R("u+w", @tmp, force: true)
    FileUtils.remove_entry(@tmp)
  end

  def make_repository
    origin = File.join(@tmp, "origin.git")
    Dir.mkdir(@repo)
    sh(@repo, "init", "-q", "-b", "main")
    sh(@repo, "config", "user.name", "Giraffe Test")
    sh(@repo, "config", "user.email", "giraffe@example.test")
    write("app.rb", "puts 'base'\n")
    commit_all("base")
    sh(@tmp, "init", "-q", "--bare", origin)
    sh(@repo, "remote", "add", "origin", origin)
    sh(@repo, "push", "-q", "-u", "origin", "main")
  end

  def sh(directory, *args)
    out, err, status = Open3.capture3("git", *args, chdir: directory)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
    out
  end

  def write(name, content, directory: @repo)
    FileUtils.mkdir_p(File.dirname(File.join(directory, name)))
    File.write(File.join(directory, name), content)
  end

  def commit_all(message, directory: @repo)
    sh(directory, "add", "-A")
    sh(directory, "commit", "-q", "-m", message)
    sh(directory, "rev-parse", "HEAD").strip
  end

  def head(directory = @repo) = sh(directory, "rev-parse", "HEAD").strip
  def head_of(ref) = sh(@repo, "rev-parse", ref).strip
  def branch(directory = @repo) = sh(directory, "branch", "--show-current").strip

  def install_hook(body, name: "post-checkout")
    hook = File.join(@repo, ".git/hooks", name)
    File.write(hook, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, hook)
  end

  def registered_worktrees = sh(@repo, "worktree", "list", "--porcelain").lines.grep(/\Aworktree /).map { |line| line.chomp.delete_prefix("worktree ") }

  def worktree(path: File.join(@tmp, "tree"), branch: "run-a", base: "main", git: @git, repo: @repo)
    git.worktree(repo: repo, path: path, branch: branch, base: base)
  end

  # Status lists the path a rename or copy came from right after the path it went to.
  def assert_follows(paths, first, second)
    assert_equal second, paths[paths.index(first) + 1], "#{second} should follow #{first} in #{paths.inspect}"
  end

  ## Making a worktree

  def test_worktree_is_a_new_branch_at_the_commit_the_base_names_and_the_manifest_says_so
    first = head
    sh(@repo, "tag", "-a", "v1", "-m", "release", first)
    write("app.rb", "puts 'second'\n")
    commit_all("second")
    path = File.join(@tmp, "runs/deeper/tree")
    manifest = worktree(path: path, base: "v1")
    assert_equal %w[path branch base_sha common_git_dir], manifest.keys
    assert_equal({"path" => path, "branch" => "run-a", "base_sha" => first, "common_git_dir" => File.realpath(File.join(@repo, ".git"))}, manifest)
    assert_equal first, head(path), "a tag names a commit, which the worktree starts from"
    assert_equal "run-a", branch(path)
    assert_equal "puts 'base'\n", File.read(File.join(path, "app.rb"))
    assert_includes registered_worktrees, path
  end

  def test_manifest_describes_the_worktree_by_its_resolved_path
    real = File.join(@tmp, "real")
    Dir.mkdir(real)
    File.symlink(real, File.join(@tmp, "link"))
    assert_equal File.join(real, "tree"), worktree(path: File.join(@tmp, "link", "tree"))["path"]
  end

  def test_common_git_dir_is_the_same_from_the_repository_and_from_its_worktrees
    path = worktree["path"]
    assert_equal File.realpath(File.join(@repo, ".git")), @git.common(@repo)
    assert_equal @git.common(@repo), @git.common(path)
  end

  def test_a_branch_name_git_refuses_is_the_first_thing_refused
    # Both the base and the path would be refused too, if the branch name were not looked at first.
    File.write(File.join(@tmp, "tree"), "in the way")
    error = assert_raises(Giraffe::Error) { worktree(branch: "bad..name", base: "no-such-ref") }
    assert_match(/\Agit failed \(\d+\): .*'bad\.\.name' is not a valid branch name/, error.message)
  end

  def test_a_base_that_is_not_a_commit_is_refused_and_nothing_is_made
    ["no-such-ref", "main^{tree}"].each do |base|
      assert_raises(Giraffe::Error) { worktree(base: base) }
    end
    refute File.exist?(File.join(@tmp, "tree"))
    assert_empty sh(@repo, "branch", "--list", "run-a")
  end

  def test_a_branch_that_already_exists_is_never_adopted
    taken = head
    sh(@repo, "branch", "taken", taken)
    error = assert_raises(Giraffe::Error) { worktree(branch: "taken") }
    assert_equal "branch already exists outside this run: taken", error.message
    refute File.exist?(File.join(@tmp, "tree"))
    assert_equal taken, head_of("taken")
  end

  def test_an_unfinished_worktree_of_the_same_branch_is_made_again_from_the_base
    path = worktree["path"]
    write("app.rb", "puts 'work done in the dead worktree'\n", directory: path)
    commit_all("work", directory: path)
    write("stray.txt", "left by a hook that died", directory: path)
    sh(@repo, "worktree", "lock", path)
    manifest = worktree
    assert_equal path, manifest["path"]
    refute File.exist?(File.join(path, "stray.txt")), "it is made again, so nothing of the old one stays"
    assert_equal manifest["base_sha"], head_of("run-a"), "the branch starts over from the base"
    assert_equal [@repo, path].sort, registered_worktrees.sort
  end

  def test_a_hook_failing_while_the_worktree_is_made_is_reported_and_the_worktree_made_again
    once = File.join(@tmp, "failed-once")
    install_hook("if [ ! -e #{once} ]; then touch #{once} stray.txt; echo 'could not fetch gems' >&2; exit 1; fi")
    assert_match(/could not fetch gems/, assert_raises(Giraffe::Error) { worktree }.message)
    assert File.directory?(File.join(@tmp, "tree")), "git leaves the worktree it died making"
    manifest = worktree
    refute File.exist?(File.join(manifest["path"], "stray.txt"))
    assert_equal manifest["base_sha"], head(manifest["path"])
  end

  def test_a_path_that_is_not_this_runs_unfinished_worktree_is_left_alone
    file = File.join(@tmp, "a-file")
    File.write(file, "mine")
    plain = File.join(@tmp, "plain")
    inside = File.join(@repo, "inside")
    other_branch = File.join(@tmp, "other-branch")
    theirs = File.join(@tmp, "theirs")
    [plain, inside].each { |directory| write("keep", "mine", directory: directory) }
    sh(@repo, "worktree", "add", "-q", "-b", "other", other_branch, "main")
    sh(@tmp, "clone", "-q", @repo, File.join(@tmp, "clone"))
    sh(File.join(@tmp, "clone"), "worktree", "add", "-q", "-b", "run-a", theirs, "main")

    assert_equal "unexpected existing worktree path: #{file}", assert_raises(Giraffe::Error) { worktree(path: file) }.message
    assert_raises(Giraffe::Error) { worktree(path: plain) }
    assert_equal "unexpected existing worktree path: #{inside}", assert_raises(Giraffe::Error) { worktree(path: inside) }.message
    assert_equal "worktree belongs to another branch", assert_raises(Giraffe::Error) { worktree(path: other_branch) }.message
    assert_equal "worktree belongs to another repository", assert_raises(Giraffe::Error) { worktree(path: theirs) }.message

    [file, File.join(plain, "keep"), File.join(inside, "keep")].each { |kept| assert_equal "mine", File.read(kept) }
    assert_includes registered_worktrees, other_branch
    assert_equal "other", branch(other_branch)
    assert_includes sh(File.join(@tmp, "clone"), "worktree", "list", "--porcelain"), theirs
  end

  ## Hooks and the environment checkouts run them in

  def test_checkouts_give_a_hook_time_and_none_of_the_harness_credentials
    seen = File.join(@tmp, "hook-env.txt")
    install_hook("env >> #{seen}")
    %w[ANTHROPIC_API_KEY GH_TOKEN LINEAR_API_KEY].each { |name| ENV[name] = "controller-credential" }
    command = RecordingCommand.new
    git = Giraffe::Git.new(command: command)
    worktree(git: git)
    git.at_commit(@repo, head) { |_tree| nil }
    assert_equal 2, command.checkouts.size
    command.checkouts.each do |_argv, options|
      assert_equal 600, options[:timeout]
      assert options[:clean_env]
      assert_equal ENV.slice(*Giraffe::Command::PROJECT_ENV), options[:env]
      assert_equal Giraffe::Git::BOOKKEEPING_LIMIT, options[:limit]
    end
    env = File.read(seen)
    assert_includes env, "PATH="
    %w[ANTHROPIC_API_KEY GH_TOKEN LINEAR_API_KEY].each { |name| refute_includes env, name }
  end

  def test_removing_a_worktree_is_forced_twice_because_a_dead_checkout_stays_locked
    command = RecordingCommand.new
    git = Giraffe::Git.new(command: command)
    path = worktree(git: git)["path"]
    sh(@repo, "worktree", "lock", path)
    worktree(git: git)
    assert_equal [["git", "worktree", "remove", "--force", "--force", path]], command.removals.map(&:first)
  end

  ## Proof checkouts

  def test_at_commit_checks_out_that_commit_alone_and_takes_it_away_afterwards
    first = head
    write("app.rb", "puts 'second'\n")
    commit_all("second")
    write("app.rb", "puts 'not committed'\n")
    seen = nil
    result = @git.at_commit(@repo, first) do |tree|
      seen = {tree: tree, source: File.read(File.join(tree, "app.rb")), head: head(tree), branch: branch(tree), entries: Dir.children(File.dirname(tree))}
      File.write(File.join(File.dirname(tree), "shots"), "kept beside the tree, removed with it")
      :the_blocks_value
    end
    assert_equal :the_blocks_value, result
    assert_equal({source: "puts 'base'\n", head: first, branch: "", entries: ["tree"]}, seen.slice(:source, :head, :branch, :entries))
    assert_equal "tree", File.basename(seen[:tree])
    assert_equal @scratch, File.dirname(File.dirname(seen[:tree]))
    assert File.basename(File.dirname(seen[:tree])).start_with?("giraffe-proof-")
    assert_empty Dir.children(@scratch)
    assert_equal [@repo], registered_worktrees
  end

  def test_at_commit_takes_the_checkout_away_when_the_block_raises
    boom = Class.new(StandardError)
    tree = nil
    assert_raises(boom) do
      @git.at_commit(@repo, head) do |made|
        tree = made
        raise boom
      end
    end
    refute File.exist?(tree)
    assert_empty Dir.children(@scratch)
    assert_equal [@repo], registered_worktrees
  end

  def test_each_at_commit_gets_a_checkout_of_its_own
    trees = []
    2.times { @git.at_commit(@repo, head) { |tree| trees << tree } }
    @git.at_commit(@repo, head) do |outer|
      @git.at_commit(@repo, head) do |inner|
        trees.push(outer, inner)
        assert_equal [@repo, outer, inner].sort, registered_worktrees.sort
      end
    end
    assert_equal trees.size, trees.uniq.size
    assert_empty Dir.children(@scratch)
    assert_equal [@repo], registered_worktrees
  end

  def test_at_commit_of_a_commit_git_cannot_find_reports_that_and_has_nothing_to_remove
    command = RecordingCommand.new
    error = assert_raises(Giraffe::Error) { Giraffe::Git.new(command: command).at_commit(@repo, "0" * 40) { |_tree| flunk "there is nothing to check out" } }
    assert_match(/invalid reference/, error.message)
    assert_empty command.removals, "a checkout that was never made is not removed, which would hide why it was not made"
    assert_empty Dir.children(@scratch)
  end

  def test_proof_checkout_whose_hook_fails_reports_it_and_leaves_nothing_registered
    install_hook("echo 'bundle install failed' >&2; exit 1")
    ran = false
    error = assert_raises(Giraffe::Error) { @git.at_commit(@repo, head) { |_tree| ran = true } }
    assert_match(/bundle install failed/, error.message)
    refute ran
    assert_equal [@repo], registered_worktrees
    assert_empty Dir.children(@scratch)
  end

  def test_a_read_only_directory_left_in_a_checkout_does_not_stop_it_being_removed
    leftover = nil
    @git.at_commit(@repo, head) do |tree|
      leftover = tree
      write("cache/ro/x", "", directory: tree)
      File.chmod(0o500, File.join(tree, "cache/ro"))
    end
    refute File.exist?(leftover)
    assert_equal [@repo], registered_worktrees
  end

  ## The fingerprint a read-only step is held to

  def expected_fingerprint(directory = @repo)
    stripped = ->(*args) { sh(directory, *args).strip }
    {"head" => stripped.("rev-parse", "HEAD"), "branch" => stripped.("symbolic-ref", "--short", "HEAD"),
     "common_git_dir" => File.realpath(File.join(directory, ".git")), "origin" => stripped.("remote", "get-url", "origin"),
     "push_origin" => stripped.("remote", "get-url", "--push", "origin"), "status" => stripped.("status", "--porcelain=v1", "--untracked-files=all"),
     "diff" => Digest::SHA256.hexdigest(stripped.("diff", "--binary", "HEAD", "--")), "index" => Digest::SHA256.hexdigest(stripped.("ls-files", "--stage"))}
  end

  # The same bytes every time but one, and a NUL among them so that git takes it for binary.
  def binary(byte) = (0..255).to_a.pack("C*").tap { |bytes| bytes.setbyte(10, byte) }

  def make_the_tree_untidy
    write("blob.bin", binary(0))
    commit_all("a binary file")
    sh(@repo, "remote", "set-url", "--push", "origin", File.join(@tmp, "push-only.git"))
    write("app.rb", "puts 'edited'\n")
    write("blob.bin", binary(2))
    write("staged.rb", "puts 'staged'\n")
    sh(@repo, "add", "staged.rb")
    write("untracked/deep/file.rb", "puts 'untracked'\n")
  end

  def test_fingerprint_is_the_commit_the_branch_the_remotes_and_the_state_of_the_tree
    assert_equal expected_fingerprint, @git.fingerprint(@repo)
    make_the_tree_untidy
    fingerprint = @git.fingerprint(@repo)
    assert_equal expected_fingerprint, fingerprint
    assert_equal %w[head branch common_git_dir origin push_origin status diff index], fingerprint.keys
    refute_equal fingerprint["origin"], fingerprint["push_origin"]
    refute_equal Digest::SHA256.hexdigest(""), fingerprint["diff"]
  end

  def test_fingerprint_needs_a_branch_to_name
    sh(@repo, "checkout", "-q", "--detach")
    assert_raises(Giraffe::Error) { @git.fingerprint(@repo) }
  end

  def test_fingerprint_moves_with_every_part_of_what_a_read_only_step_must_not_change
    write("blob.bin", binary(0))
    commit_all("a binary file")
    still = @git.fingerprint(@repo)
    FileUtils.touch(File.join(@repo, "app.rb"))
    assert_equal still, @git.fingerprint(@repo), "touching a file changes nothing"
    write("blob.bin", binary(2))
    first_edit = @git.fingerprint(@repo)
    write("blob.bin", binary(3))
    second_edit = @git.fingerprint(@repo)
    refute_equal first_edit["diff"], second_edit["diff"], "two different edits of a binary file are two different diffs"
    assert_equal first_edit["status"], second_edit["status"]
    sh(@repo, "add", "blob.bin")
    refute_equal second_edit["index"], @git.fingerprint(@repo)["index"]
    sh(@repo, "checkout", "-q", "-b", "elsewhere")
    assert_equal "elsewhere", @git.fingerprint(@repo)["branch"]
    commit_all("work on it")
    refute_equal second_edit["head"], @git.fingerprint(@repo)["head"]
  end

  def test_read_only_returns_what_its_block_returns_and_refuses_a_block_that_changed_the_tree
    assert_equal :unchanged, @git.read_only(@repo) { :unchanged }
    error = assert_raises(Giraffe::Error) { @git.read_only(@repo) { write("app.rb", "puts 'changed'\n") } }
    assert_equal "read-only step changed the candidate or working tree", error.message
    assert_equal "puts 'changed'\n", File.read(File.join(@repo, "app.rb")), "it reports the change and leaves the tree as it found it"
  end

  ## Committing

  def test_commit_makes_one_commit_of_everything_and_returns_it
    write(".gitignore", "ignored.log\n")
    before = commit_all("ignore logs")
    write("app.rb", "puts 'edited'\n")
    write("new/dir/added.rb", "puts 'added'\n")
    write("ignored.log", "not for the commit")
    sha = @git.commit(@repo, "A title\n\nA body")
    assert_equal head, sha
    assert_equal before, sh(@repo, "rev-parse", "HEAD~1").strip
    assert_equal "A title\n\nA body", sh(@repo, "log", "-1", "--format=%B").strip
    assert_equal %W[M\tapp.rb A\tnew/dir/added.rb], sh(@repo, "show", "--name-status", "--format=", "HEAD").lines.map(&:chomp)
    assert_empty sh(@repo, "status", "--porcelain=v1")
  end

  def test_commit_with_nothing_to_commit_returns_nil_and_adds_no_commit
    write(".gitignore", "ignored.log\n")
    commit_all("ignore logs")
    before = head
    write("ignored.log", "not a change")
    assert_nil @git.commit(@repo, "nothing")
    assert_equal before, head
  end

  def test_commit_deletes_what_was_deleted
    File.delete(File.join(@repo, "app.rb"))
    sha = @git.commit(@repo, "remove app")
    assert_equal head, sha
    assert_equal "", sh(@repo, "ls-files").strip
  end

  def test_commit_runs_no_hooks
    marker = File.join(@tmp, "hook-ran")
    %w[pre-commit commit-msg post-commit].each { |name| install_hook("touch #{marker}; exit 1", name: name) }
    write("app.rb", "puts 'edited'\n")
    sha = @git.commit(@repo, "no hooks")
    assert_equal head, sha
    refute File.exist?(marker)
  end

  def test_commit_refuses_to_go_on_when_git_cannot_say_whether_anything_is_staged
    broken = {%w[git diff --cached --quiet] => -> { {"status" => 2, "stdout" => "", "stderr" => "cannot say"} }}
    before = head
    write("app.rb", "puts 'edited'\n")
    error = assert_raises(Giraffe::Error) { Giraffe::Git.new(command: RecordingCommand.new(broken)).commit(@repo, "edit") }
    assert_equal "could not inspect staged change", error.message
    assert_equal before, head
  end

  def test_commit_checks_the_tree_is_clean_afterwards
    dirty = {%w[git status --porcelain=v1 --untracked-files=all] => -> { {"status" => 0, "stdout" => " M app.rb\n", "stderr" => ""} }}
    write("app.rb", "puts 'edited'\n")
    error = assert_raises(Giraffe::Error) { Giraffe::Git.new(command: RecordingCommand.new(dirty)).commit(@repo, "edit") }
    assert_equal "worktree is dirty; inspect or restore interrupted work before resuming: #{@repo}", error.message
  end

  ## What changed in the tree

  def test_changed_paths_of_a_clean_tree_is_empty
    assert_empty @git.changed_paths(@repo)
  end

  def test_changed_paths_lists_every_path_status_reports_and_the_old_path_of_a_rename_or_copy
    sh(@repo, "config", "status.renames", "copies")
    body = (1..30).map { |number| "line #{number}\n" }.join
    {"keep.txt" => "keep\n", "edit.txt" => "edit\n", "gone.txt" => "gone\n", "old name.txt" => body,
     "source.txt" => "#{body}tail\n", ".gitignore" => "ignored.log\n"}.each { |name, text| write(name, text) }
    commit_all("files to change")
    write("edit.txt", "edited\n")
    File.delete(File.join(@repo, "gone.txt"))
    sh(@repo, "mv", "old name.txt", "new name.txt")
    FileUtils.cp(File.join(@repo, "source.txt"), File.join(@repo, "copy of source.txt"))
    write("source.txt", "#{body}tail\nmore\n")
    sh(@repo, "add", "-A")
    ["sub/dir/untracked.txt", "ünï.txt", "line\nbreak.txt", "ignored.log"].each { |name| write(name, "untracked\n") }
    paths = @git.changed_paths(@repo)
    assert_equal ["copy of source.txt", "edit.txt", "gone.txt", "line\nbreak.txt", "new name.txt", "old name.txt", "source.txt", "source.txt", "sub/dir/untracked.txt", "ünï.txt"], paths.sort
    assert_follows(paths, "new name.txt", "old name.txt")
    assert_follows(paths, "copy of source.txt", "source.txt")
  end

  def test_changed_file_states_describe_each_changed_path_by_what_is_on_disk
    write("dir/file.txt", "inner\n")
    %w[plain.txt run.sh gone.txt].each { |name| write(name, "#{name}\n") }
    File.symlink("plain.txt", File.join(@repo, "link"))
    commit_all("kinds of file")
    write("plain.txt", "plain, changed\n")
    File.chmod(0o755, File.join(@repo, "run.sh"))
    File.delete(File.join(@repo, "gone.txt"))
    FileUtils.rm_rf(File.join(@repo, "dir"))
    File.write(File.join(@repo, "dir"), "now a file\n")
    File.delete(File.join(@repo, "link"))
    File.symlink("elsewhere", File.join(@repo, "link"))
    File.symlink("missing", File.join(@repo, "dangling"))
    nested = File.join(@repo, "nested")
    write("inside.txt", "inside\n", directory: nested)
    sh(nested, "init", "-q")

    states = @git.changed_file_states(@repo)
    mode = ->(name) { File.lstat(File.join(@repo, name)).mode }
    assert_equal({"plain.txt" => ["file", mode.("plain.txt"), Digest::SHA256.hexdigest("plain, changed\n")],
                  "run.sh" => ["file", mode.("run.sh"), Digest::SHA256.hexdigest("run.sh\n")],
                  "link" => ["link", mode.("link"), "elsewhere"], "dangling" => ["link", mode.("dangling"), "missing"],
                  "dir" => ["file", mode.("dir"), Digest::SHA256.hexdigest("now a file\n")], "nested/" => ["directory", mode.("nested"), nil],
                  "gone.txt" => nil, "dir/file.txt" => nil}, states)
  end
end
