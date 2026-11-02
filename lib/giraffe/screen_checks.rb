# frozen_string_literal: true

require "digest"
require "fileutils"

module Giraffe
  # Runs what a repository declares to look at its screens, in a checkout of its own, and keeps what they draw.
  # A browser suite needs the network, so these alone get it. They are still the candidate's code, so the rest of
  # the sandbox holds.
  class ScreenChecks
    def initialize(git:, checks:, worktree:, commands:)
      @git, @checks, @worktree, @commands = git, checks, worktree, commands
    end

    # What each command did, and the pictures they left, copied under `keep_in` by the names they gave them.
    def run(candidate, keep_in)
      @git.at_commit(@worktree, candidate) do |tree|
        shots = File.join(File.dirname(tree), "shots")
        FileUtils.mkdir_p(shots)
        results = @commands.map { |argv| run_one(tree, argv, shots) }
        [results, keep(shots, keep_in)]
      end
    end

    private

    # Recorded as declared: the directory it was given is gone by the time anyone reads this.
    def run_one(tree, argv, shots)
      @checks.run(tree, [argv.map { |arg| arg.gsub("{shots}", shots) }], network: true).first.merge("command" => argv)
    end

    # Regular files only: the candidate's code chose what is here, and a link could point anywhere.
    def keep(shots, keep_in)
      Dir.glob("**/*.png", base: shots).sort.filter_map do |name|
        source = File.join(shots, name)
        copy(source, File.join(keep_in, name), name) if File.lstat(source).file?
      end
    end

    def copy(source, target, name)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(source, target)
      {"name" => name, "path" => target, "sha256" => Digest::SHA256.file(target).hexdigest, "bytes" => File.size(target)}
    end
  end
end
