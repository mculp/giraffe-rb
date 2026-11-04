# frozen_string_literal: true

module Giraffe
  # What BUILD is told not to touch and may not commit: git's own files, instruction files, credentials and the
  # hooks a checkout will run. A candidate that rewrote them would act with more authority than its ticket gave it.
  class ProtectedPaths
    PATTERN = %r{(^|/)(\.git|\.claude|\.cursor|\.giraffe|\.husky|\.env(?:\..*)?|credentials)(/|$)|(^|/)(CLAUDE|AGENTS)\.md$|\.(pem|key)$}

    # The directory, slash included, where the repository keeps its hooks when that is inside the tree.
    def initialize(hooks_prefix: nil) = @hooks_prefix = hooks_prefix

    def among(paths) = paths.select { |path| protected?(path) }

    private

    def protected?(path) = path.match?(PATTERN) || (@hooks_prefix && path.start_with?(@hooks_prefix))
  end
end
