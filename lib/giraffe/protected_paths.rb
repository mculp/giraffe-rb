# frozen_string_literal: true

module Giraffe
  # What BUILD is told not to touch and may not commit: git's own files, instruction files, credentials and the
  # hooks a checkout will run. A candidate that rewrote them would act with more authority than its ticket gave it.
  class ProtectedPaths
    # Case-insensitive because macOS's default volume treats `claude.md` and `CLAUDE.md` as the same file.
    PATTERN = %r{(^|/)(\.git|\.claude|\.cursor|\.giraffe|\.husky|\.env(?:\..*)?|credentials)(/|$)|(^|/)(CLAUDE|AGENTS)\.md$|\.(pem|key)$}i

    # Every hook git documents in githooks(5); with `core.hooksPath` at the root, git runs any of them from there.
    HOOK_NAMES = %w[applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg
                    commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive
                    post-receive post-update reference-transaction push-to-checkout pre-auto-gc post-rewrite
                    sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist
                    p4-pre-submit post-index-change].freeze

    # What Git#hooks_prefix returns when hooks live in the repository root itself.
    ROOT = "./"

    # The directory, slash included, where the repository keeps its hooks when that is inside the tree.
    def initialize(hooks_prefix: nil) = @hooks_prefix = hooks_prefix&.downcase

    def among(paths) = paths.select { |path| protected?(path) }

    private

    def protected?(path) = path.match?(PATTERN) || hook?(path.downcase)

    def hook?(path)
      return false unless @hooks_prefix

      @hooks_prefix == ROOT ? HOOK_NAMES.include?(path) : path.start_with?(@hooks_prefix)
    end
  end
end
