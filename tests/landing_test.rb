# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/giraffe/landing"

# Real repositories: a bare origin, a checkout that lands, and another that moves main underneath it.
class LandingTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("giraffe-landing-test-")
    @origin = File.join(@tmp, "origin.git")
    sh(@tmp, "git", "init", "-q", "--bare", "-b", "main", @origin)
    @work = clone("work")
    commit(@work, "README.md", "one\n", "start")
    sh(@work, "git", "push", "-q", "origin", "HEAD:main")
    @landing = Giraffe::Landing.new
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def sh(dir, *argv)
    out, status = Open3.capture2e({"GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t"}, *argv, chdir: dir)
    raise "#{argv.join(' ')}: #{out}" unless status.success?
    out.strip
  end

  def clone(name)
    path = File.join(@tmp, name)
    sh(@tmp, "git", "clone", "-q", @origin, path)
    sh(path, "git", "checkout", "-q", "-B", "main")
    path
  end

  def commit(dir, file, text, message)
    File.write(File.join(dir, file), text)
    sh(dir, "git", "add", file)
    sh(dir, "git", "commit", "-q", "-m", message)
    sh(dir, "git", "rev-parse", "HEAD")
  end

  def origin_main = sh(@tmp, "git", "--git-dir", @origin, "rev-parse", "main")

  def test_a_commit_on_top_of_main_lands
    sha = commit(@work, "a.txt", "a\n", "CHUNKY-1 add a")
    result = @landing.land(@work, sha: sha)
    assert result.landed?
    assert_equal sha, origin_main
  end

  def test_a_commit_cut_from_an_older_main_is_behind_and_nothing_moves
    other = clone("other")
    moved = commit(other, "b.txt", "b\n", "CHUNKY-2 add b")
    sh(other, "git", "push", "-q", "origin", "HEAD:main")
    sha = commit(@work, "a.txt", "a\n", "CHUNKY-1 add a")
    result = @landing.land(@work, sha: sha)
    assert result.behind?
    assert_equal moved, result.base_sha
    assert_equal moved, origin_main
  end

  def test_a_rebased_commit_lands_after_main_moved
    other = clone("other")
    commit(other, "b.txt", "b\n", "CHUNKY-2 add b")
    sh(other, "git", "push", "-q", "origin", "HEAD:main")
    commit(@work, "a.txt", "a\n", "CHUNKY-1 add a")
    rebased = @landing.rebase(@work)
    assert @landing.land(@work, sha: rebased).landed?
    assert_equal rebased, origin_main
    assert_equal "CHUNKY-1 add a", sh(@work, "git", "log", "-1", "--format=%s", rebased)
  end

  def test_a_conflicting_rebase_raises_and_leaves_the_work_alone
    other = clone("other")
    commit(other, "README.md", "theirs\n", "CHUNKY-2 change readme")
    sh(other, "git", "push", "-q", "origin", "HEAD:main")
    mine = commit(@work, "README.md", "mine\n", "CHUNKY-1 change readme")
    assert_raises(Giraffe::Error) { @landing.rebase(@work) }
    assert_equal mine, sh(@work, "git", "rev-parse", "HEAD")
    assert_empty sh(@work, "git", "status", "--porcelain")
  end

  def test_a_push_hook_never_runs
    hook = File.join(@work, ".git", "hooks", "pre-push")
    File.write(hook, "#!/bin/sh\ntouch #{File.join(@tmp, 'hook-ran')}\nexit 1\n")
    File.chmod(0o755, hook)
    sha = commit(@work, "a.txt", "a\n", "CHUNKY-1 add a")
    assert @landing.land(@work, sha: sha).landed?
    refute File.exist?(File.join(@tmp, "hook-ran"))
  end

  def test_main_already_at_the_commit_is_landed_without_a_push
    assert @landing.land(@work, sha: origin_main).landed?
  end
end
