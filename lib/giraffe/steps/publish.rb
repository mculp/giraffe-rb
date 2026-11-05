# frozen_string_literal: true

require_relative "../errors"
require_relative "publish/recovery"

module Giraffe
  module Steps
    # Pushes the verified candidate and opens its draft pull request. This can stop after GitHub has the pull request
    # and before the attempt ends, so a retry looks for the one it recorded before it makes another.
    class Publish
      def call(context)
        @context = context
        candidate = verified_candidate
        saved = context.attempted_artifact("publish_manifest")
        number = saved ? Recovery.new(github: context.github, repo: repo).confirm!(saved, candidate) : publish(candidate)
        context.finish(pr: number, candidate_sha: candidate)
      end

      private

      def verified_candidate
        git.clean!(worktree)
        candidate = @context.artifact_record("verification").fetch("candidate_sha")
        raise Error, "verified candidate changed before publication" unless git.head(worktree) == candidate
        candidate
      end

      def publish(candidate)
        title, file = write_description
        manifest = open_draft(title, file)
        @context.put("publish_manifest", manifest, candidate: candidate, perspective: "external_service")
        manifest.fetch("pull_request").fetch("number")
      end

      # The model writes the pull request's title and body, and GitHub is handed the body as a file.
      def write_description
        written = @context.ask("pr_body", {"diff" => git.diff(worktree, @context.base_sha), "verification" => @context.artifact("verification"), "ui_proof_pending" => @context.runtime["ui"]})
        file = File.join(@context.run.directory, "pr-body.md")
        File.write(file, written.fetch("body"), mode: "w", perm: 0o600)
        [written.fetch("title"), file]
      end

      # Publication is a harness capability. A retried publish reuses a matching open PR and
      # validates GitHub's actual head SHA and draft state before recording success.
      def open_draft(title, file)
        branch = @context.artifact("worktree_manifest").fetch("branch")
        git.push(worktree, branch)
        manifest = @context.github.publish(repo: repo, worktree: worktree, base: @context.run.config["pr_base"], head: branch, title: title, body_file: file)
        confirm_draft!(manifest)
      end

      def confirm_draft!(manifest)
        raise Error, "publication did not produce a draft PR" unless manifest.fetch("pull_request")["is_draft"]
        raise Error, "publication returned a different repository" unless manifest.dig("repository", "name_with_owner").casecmp?(repo)
        manifest
      end

      def git = @context.git
      def worktree = @context.worktree
      def repo = @context.run.config["github_repo"]
    end
  end
end
