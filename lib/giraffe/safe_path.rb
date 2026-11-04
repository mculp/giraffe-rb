# frozen_string_literal: true

require_relative "errors"

module Giraffe
  # Places a path a model named inside one checkout. It comes from a model's output, so a bad one is that output's
  # fault: every refusal is an InvalidOutput, and resuming asks the model again.
  class SafePath
    # Parts that name somewhere else, or git's own files.
    OFF_LIMITS = %w[. .. .git].freeze

    def initialize(root)
      @root = File.realpath(root)
      @inside = "#{@root}/"
    end

    # A regular file that is already there, and not by way of a link.
    def file(relative)
      path = within(relative)
      raise InvalidOutput, "proof file is missing or a symlink: #{relative}" unless regular_file?(path)
      path
    end

    # Where a file could be written, which need not exist yet. Nothing on the way there may lead out of the checkout.
    def target(relative)
      path = within(relative)
      raise InvalidOutput, "proof path follows a symlink outside the worktree: #{relative}" unless inside?(real_parent(path))
      raise InvalidOutput, "proof target is a symlink: #{relative}" if File.symlink?(path)
      path
    end

    private

    def within(relative)
      raise InvalidOutput, "invalid relative proof path: #{relative}" if unusable?(relative)
      path = File.expand_path(relative, @root)
      raise InvalidOutput, "proof path escapes its worktree: #{relative}" unless path.start_with?(@inside)
      path
    end

    # A leading dash is an option to whatever command is handed the path.
    def unusable?(relative) = relative.start_with?("/", "-") || relative.split("/").intersect?(OFF_LIMITS)

    def regular_file?(path) = File.file?(path) && !File.symlink?(path) && inside?(File.realpath(path))

    # Of a path with its links resolved. The slash in @inside keeps a neighbour such as "tree-secrets" from
    # passing for "tree".
    def inside?(real_path) = real_path == @root || real_path.start_with?(@inside)

    # Where a new file would really land: the nearest directory above it that exists.
    def real_parent(path)
      parent = File.dirname(path)
      parent = File.dirname(parent) until File.exist?(parent)
      File.realpath(parent)
    end
  end
end
