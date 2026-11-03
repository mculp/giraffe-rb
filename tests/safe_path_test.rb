# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/giraffe/safe_path"
require_relative "../lib/giraffe/protected_paths"

# The path a model names must stay inside the checkout it names it in. The tree here sits beside two directories a
# model must not reach: one nobody could mistake for part of it, and one whose name merely starts like its own.
class SafePathTest < Minitest::Test
  LINKS = {"to_file_outside" => "../outside.rb", "to_file_inside" => "lib/x_test.rb", "to_dir_outside" => "../elsewhere",
           "to_neighbour" => "../tree-secrets", "dangling" => "../elsewhere/new.rb"}.freeze
  LEADING_OUT = {"an absolute path" => "/etc/passwd", "a way up" => "../outside.rb", "a way up from inside" => "lib/../../outside.rb",
                 "an option for a command" => "-e", "git's own files" => ".git/config",
                 "a user's home" => "~nosuchuser/x_test.rb", "a NUL byte" => "lib/a\0b_test.rb"}.freeze

  def setup
    @base = Dir.mktmpdir("giraffe-safe-path-test-")
    @root = File.join(@base, "tree")
    build_tree
    LINKS.each { |name, to| File.symlink(to, File.join(@root, name)) }
  end

  def teardown = FileUtils.remove_entry(@base)

  def build_tree
    FileUtils.mkdir_p([File.join(@root, "lib"), File.join(@base, "elsewhere"), File.join(@base, "tree-secrets")])
    File.write(File.join(@root, "lib/x_test.rb"), "puts 1\n")
    %w[outside.rb elsewhere/y.rb tree-secrets/s.rb].each { |name| File.write(File.join(@base, name), "not for the tree\n") }
  end

  def safe_path(root = @root) = Giraffe::SafePath.new(root)
  def real(name) = File.join(File.realpath(@root), name)
  def refusal(ask, name) = assert_raises(Giraffe::InvalidOutput, "#{ask} accepted #{name.inspect}") { safe_path.public_send(ask, name) }.message

  def test_a_path_in_the_tree_comes_back_in_full
    assert_equal real("lib/x_test.rb"), safe_path.file("lib/x_test.rb")
    assert_equal real("lib/x_test.rb"), safe_path.target("lib/x_test.rb")
    assert_equal real("new/dir/spec.rb"), safe_path.target("new/dir/spec.rb"), "a target need not exist yet"
  end

  def test_a_tree_reached_through_a_link_is_the_tree_it_leads_to
    File.symlink(@root, File.join(@base, "alias"))
    assert_equal real("lib/x_test.rb"), safe_path(File.join(@base, "alias")).file("lib/x_test.rb")
  end

  def test_a_name_that_leads_out_of_the_tree_is_refused_whatever_it_is_asked_for
    LEADING_OUT.each do |what, name|
      %i[file target].each { |ask| assert_equal "invalid relative proof path: #{name}", refusal(ask, name), "#{ask}: #{what}" }
    end
  end

  def test_home_is_not_in_the_tree
    %i[file target].each { |ask| assert_equal "invalid relative proof path: ~/spec.rb", refusal(ask, "~/spec.rb") }
  end

  def test_a_tilde_inside_a_name_is_just_a_character
    assert_equal real("lib/~foo"), safe_path.target("lib/~foo")
  end

  def test_a_file_is_refused_when_it_is_a_link_or_is_reached_through_one_that_leaves_the_tree
    %w[to_file_outside to_file_inside to_dir_outside/y.rb to_neighbour/s.rb].each do |name|
      assert_equal "proof file is missing or a symlink: #{name}", refusal(:file, name)
    end
  end

  def test_a_new_file_cannot_be_placed_outside_the_tree_by_way_of_a_link
    %w[to_dir_outside/new.rb to_dir_outside/deep/new.rb to_neighbour/new.rb].each do |name|
      assert_equal "proof path follows a symlink outside the worktree: #{name}", refusal(:target, name)
    end
  end

  # Writing through a link that points at nothing yet creates what it points at.
  def test_a_link_cannot_stand_where_a_file_is_to_be_written
    %w[dangling to_file_inside].each { |name| assert_equal "proof target is a symlink: #{name}", refusal(:target, name) }
  end

  def test_a_file_has_to_be_there_but_a_target_can_be_a_directory
    %w[lib/missing.rb lib].each { |name| assert_equal "proof file is missing or a symlink: #{name}", refusal(:file, name) }
    assert_equal real("lib"), safe_path.target("lib"), "REPRODUCE asks of a target whether it is a directory"
  end
end

class ProtectedPathsTest < Minitest::Test
  PROTECTED = %w[.git/config .claude/settings.json .cursor/rules/a.mdc .giraffe/state.json .husky/pre-commit .env .env.local
                 config/.env.test credentials CLAUDE.md docs/AGENTS.md certs/server.pem config/master.key].freeze

  def protected_paths(**options) = Giraffe::ProtectedPaths.new(**options)

  def test_what_steers_the_tools_or_holds_a_secret_is_protected_wherever_it_is
    assert_equal PROTECTED, protected_paths.among(PROTECTED)
  end

  def test_any_other_file_is_free_to_change
    assert_empty protected_paths.among(%w[app.rb lib/environment.rb docs/guide.md .gitignore])
  end

  def test_it_answers_with_the_protected_ones_in_the_order_it_was_given
    assert_equal %w[.env CLAUDE.md], protected_paths.among(%w[app.rb .env lib/x.rb CLAUDE.md])
  end

  def test_the_hooks_a_checkout_runs_are_protected_where_the_repository_keeps_them
    paths = %w[hooks/post-checkout hooks-extra/x docs/hooks/x]
    assert_equal %w[hooks/post-checkout], protected_paths(hooks_prefix: "hooks/").among(paths)
    assert_empty protected_paths.among(paths), "with no hooks in the tree there is nothing more to protect"
  end
end
