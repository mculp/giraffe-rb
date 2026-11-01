# frozen_string_literal: true

module Giraffe
  module Steps
    module Publish
      def step_publish
        @git.clean!(worktree)
        candidate = artifact_record("verification").fetch("candidate_sha")
        raise Error, "verified candidate changed before publication" unless @git.head(worktree) == candidate
        if (saved = attempted_artifact("publish_manifest"))
          number = saved.fetch("pull_request").fetch("number")
          current = @github.reconcile_pr(repo: @run.config["github_repo"], pr_number: number)
          unless current.dig("pull_request", "head_sha") == candidate && current.dig("pull_request", "is_draft") &&
                 current.dig("pull_request", "state") == "open" && current.dig("pull_request", "id") == saved.dig("pull_request", "id")
            raise Error, "published PR changed during recovery"
          end
          finish(pr: number, candidate_sha: candidate)
          return
        end
        body = ask("pr_body", {"ticket" => @run.state["ticket"], "diff" => @git.diff(worktree, base_sha),
                               "verification" => artifact("verification"), "ui_proof_pending" => runtime["ui"]})
        file = File.join(@run.directory, "pr-body.md")
        File.write(file, body.fetch("body"), mode: "w", perm: 0o600)
        branch = artifact("worktree_manifest").fetch("branch")
        # Publication is a harness capability. A retried publish reuses a matching open PR and
        # validates GitHub's actual head SHA and draft state before recording success.
        @git.call(worktree, "push", "origin", "HEAD:refs/heads/#{branch}")
        manifest = @github.publish(repo: @run.config["github_repo"], worktree: worktree,
                                   base: @run.config["pr_base"], head: branch, title: body.fetch("title"), body_file: file)
        pr = manifest.fetch("pull_request")
        raise Error, "publication did not produce a draft PR" unless pr["is_draft"]
        raise Error, "publication returned a different repository" unless manifest.dig("repository", "name_with_owner").casecmp?(@run.config["github_repo"])
        put("publish_manifest", manifest, candidate: candidate, perspective: "external_service")
        finish(pr: pr.fetch("number"), candidate_sha: candidate)
      end
    end
  end
end
