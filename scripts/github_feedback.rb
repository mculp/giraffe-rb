#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "feedback_contract"
require_relative "github_pr_ci"

module PrGraph
  class GitHubFeedback
    class AdapterError < ContractError; end

    THREAD_QUERY = <<~GRAPHQL.freeze
      query($owner:String!, $name:String!, $number:Int!, $endCursor:String) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$number) {
            reviewThreads(first:100, after:$endCursor) {
              nodes {
                id isResolved isOutdated path line
                comments(first:100) {
                  totalCount
                  nodes {
                    id databaseId body updatedAt
                    commit { oid }
                    originalCommit { oid }
                    replyTo { id }
                    author {
                      login __typename
                      ... on User { id }
                      ... on Bot { id }
                      ... on Organization { id }
                    }
                  }
                }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }
    GRAPHQL

    OPEN_THREADS_QUERY = <<~GRAPHQL.freeze
      query($owner:String!, $name:String!, $number:Int!, $endCursor:String) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$number) {
            reviewThreads(first:100, after:$endCursor) {
              nodes {
                id isResolved isOutdated path line
                comments(first:1) {
                  nodes {
                    id databaseId
                    author {
                      login __typename
                      ... on User { id }
                      ... on Bot { id }
                      ... on Organization { id }
                    }
                  }
                }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }
    GRAPHQL

    def initialize(runner: CommandRunner.new, clock: -> { Time.now.utc }, contract: FeedbackContract.new,
                   author_policy_path: nil)
      author_policy_path ||= File.expand_path("../references/automated-feedback-authors-v1.json", __dir__)
      @runner = runner
      @clock = clock
      @contract = contract
      @author_policy = JSON.parse(File.read(author_policy_path))
      validate_author_policy!
    rescue JSON::ParserError => e
      error!("invalid automated feedback author policy: #{e.message}")
    end

    def reconcile(repo:, pr_number:, candidate_sha:, wake_id:, baseline_at:, previous: nil, decisions: nil)
      repository_name!(repo)
      number = positive_integer!(pr_number, "PR number")
      git_sha!(candidate_sha, "candidate SHA")
      uuid!(wake_id, "wake identity")
      timestamp!(baseline_at, "feedback baseline")
      @contract.validate!(previous) if previous

      repository = api("repos/#{repo}")
      pull_request = api("repos/#{repo}/pulls/#{number}")
      validate_pr!(pull_request, candidate_sha)
      validate_previous_identity!(previous, repository, pull_request, baseline_at) if previous

      threads, thread_by_comment = fetch_threads(repo, number)
      current = []
      current.concat(api_pages("repos/#{repo}/issues/#{number}/comments?per_page=100").flatten.map do |comment|
        normalize_issue_comment(comment)
      end)
      current.concat(api_pages("repos/#{repo}/pulls/#{number}/reviews?per_page=100").flatten.map do |review|
        normalize_review(review)
      end)
      current.concat(api_pages("repos/#{repo}/pulls/#{number}/comments?per_page=100").flatten.map do |comment|
        normalize_review_comment(comment, thread_by_comment)
      end)

      duplicates = current.group_by { |item| item["feedback_id"] }.select { |_id, items| items.length > 1 }.keys
      error!("duplicate remote feedback identity: #{duplicates.join(', ')}") if duplicates.any?

      observed = observed_at
      previous_items = Array(previous && previous["feedback"]).to_h { |item| [item.fetch("feedback_id"), item] }
      current.map! { |item| attach_previous_revision(item, previous_items[item.fetch("feedback_id")]) }
      current_ids = current.to_h { |item| [item.fetch("feedback_id"), true] }
      previous_items.each_value do |item|
        next if current_ids.key?(item.fetch("feedback_id"))

        current << deleted_item(item, observed) unless item["remote_state"] == "deleted"
        current << item if item["remote_state"] == "deleted"
      end
      current.sort_by! { |item| [item.fetch("kind"), item.fetch("feedback_id")] }

      referenced_threads = current.map { |item| item["thread_id"] }.compact.uniq
      thread_index = threads.to_h { |thread| [thread.fetch("thread_id"), thread] }
      Array(previous && previous["threads"]).each do |thread|
        thread_index[thread.fetch("thread_id")] ||= thread if referenced_threads.include?(thread.fetch("thread_id"))
      end
      error!("review comment thread identity disappeared") unless (referenced_threads - thread_index.keys).empty?
      threads = thread_index.values.sort_by { |thread| thread.fetch("thread_id") }

      ledger = build_ledger(current, previous, decisions, observed)
      manifest = {
        "schema_version" => 1,
        "author_policy_version" => @author_policy.fetch("author_policy_version"),
        "baseline_at" => baseline_at,
        "observed_at" => observed,
        "repository_id" => repository.fetch("node_id"),
        "pull_request_id" => pull_request.fetch("node_id"),
        "pr_number" => pull_request.fetch("number"),
        "candidate_sha" => candidate_sha,
        "wake_id" => wake_id,
        "overall" => derive_overall(current, ledger),
        "feedback" => current,
        "threads" => threads,
        "ledger" => ledger
      }
      @contract.validate!(manifest)
      manifest
    rescue KeyError, JSON::ParserError => e
      error!("malformed GitHub feedback response: #{e.message}")
    end

    # Every review thread with its live resolution and the classified author of its first comment.
    def review_threads(repo:, pr_number:)
      repository_name!(repo)
      number = positive_integer!(pr_number, "PR number")
      graphql_thread_pages(repo, number, OPEN_THREADS_QUERY).map do |thread|
        thread_id = identity!(thread["id"], "review thread identity")
        first = thread.dig("comments", "nodes", 0) || error!("review thread #{thread_id} has no comments")
        {
          "thread_id" => thread_id,
          "is_resolved" => thread.fetch("isResolved"),
          "is_outdated" => thread.fetch("isOutdated"),
          "path" => thread["path"],
          "line" => thread["line"],
          "comment_id" => identity!(first["id"], "review thread comment identity"),
          "author" => classify_author(first["author"])
        }
      end
    rescue KeyError, JSON::ParserError => e
      error!("malformed GitHub review thread response: #{e.message}")
    end

    private

    def api(endpoint)
      JSON.parse(@runner.capture("gh", "api", "-H", "Accept: application/vnd.github+json", endpoint))
    end

    def api_pages(endpoint)
      value = JSON.parse(@runner.capture(
        "gh", "api", "--paginate", "--slurp", "-H", "Accept: application/vnd.github+json", endpoint
      ))
      unless value.is_a?(Array) && value.any? && value.all? { |page| page.is_a?(Array) }
        error!("paginated GitHub feedback response must contain array pages")
      end
      value
    end

    def graphql_thread_pages(repo, number, query)
      owner, name = repo.split("/", 2)
      raw_pages = JSON.parse(@runner.capture(
        "gh", "api", "graphql", "--paginate", "--slurp",
        "-f", "query=#{query}", "-F", "owner=#{owner}", "-F", "name=#{name}", "-F", "number=#{number}"
      ))
      unless raw_pages.is_a?(Array) && raw_pages.any? && raw_pages.all? { |page| page.is_a?(Hash) }
        error!("paginated review thread response must contain object pages")
      end
      raw_pages.flat_map do |page|
        page.dig("data", "repository", "pullRequest", "reviewThreads", "nodes") ||
          error!("review thread response is missing nodes")
      end
    end

    def fetch_threads(repo, number)
      raw_threads = graphql_thread_pages(repo, number, THREAD_QUERY)
      threads = []
      by_comment = {}
      raw_threads.each do |thread|
        thread_id = identity!(thread["id"], "review thread identity")
        comments = thread.dig("comments", "nodes") || error!("review thread #{thread_id} is missing comments")
        total = thread.dig("comments", "totalCount")
        error!("review thread #{thread_id} has unpaginated nested comments") unless total.is_a?(Integer) && total == comments.length
        error!("review thread #{thread_id} has no comments") if comments.empty?
        comment_ids = comments.map do |comment|
          comment_id = identity!(comment["id"], "review thread comment identity")
          error!("review comment #{comment_id} belongs to multiple threads") if by_comment.key?(comment_id)
          comment_id
        end
        updated_at = comments.map { |comment| comment["updatedAt"] }.compact.max
        timestamp!(updated_at, "review thread updated_at")
        relevant_sha = comments.reverse_each.lazy.map do |comment|
          comment.dig("commit", "oid") || comment.dig("originalCommit", "oid")
        end.find(&:itself)
        git_sha!(relevant_sha, "review thread relevant SHA") if relevant_sha
        content_source = {
          "path" => thread["path"], "line" => thread["line"], "comment_ids" => comment_ids
        }
        revision_source = content_source.merge(
          "is_resolved" => thread.fetch("isResolved"),
          "is_outdated" => thread.fetch("isOutdated"),
          "updated_at" => updated_at,
          "relevant_sha" => relevant_sha
        )
        normalized = {
          "thread_id" => thread_id,
          "revision" => digest(revision_source),
          "content_sha256" => digest(content_source),
          "is_resolved" => thread.fetch("isResolved"),
          "is_outdated" => thread.fetch("isOutdated"),
          "path" => thread["path"],
          "line" => thread["line"],
          "comment_ids" => comment_ids,
          "relevant_sha" => relevant_sha,
          "updated_at" => updated_at
        }
        threads << normalized
        comment_ids.each { |comment_id| by_comment[comment_id] = normalized }
      end
      [threads, by_comment]
    end

    def normalize_issue_comment(comment)
      normalize_feedback(
        kind: "issue_comment",
        remote_id: comment["node_id"],
        database_id: comment["id"],
        body: comment["body"],
        author: comment["user"],
        relevant_sha: nil,
        updated_at: comment["updated_at"],
        review_state: nil,
        thread_id: nil,
        resolution_state: "not_applicable"
      )
    end

    def normalize_review(review)
      normalize_feedback(
        kind: "review",
        remote_id: review["node_id"],
        database_id: review["id"],
        body: review["body"],
        author: review["user"],
        relevant_sha: review["commit_id"],
        updated_at: review["submitted_at"],
        review_state: review["state"],
        thread_id: nil,
        resolution_state: "not_applicable"
      )
    end

    def normalize_review_comment(comment, thread_by_comment)
      remote_id = identity!(comment["node_id"], "review comment identity")
      thread = thread_by_comment[remote_id] || error!("review comment #{remote_id} is missing its thread identity")
      resolution_state = if thread["is_resolved"]
                           "resolved"
                         elsif thread["is_outdated"]
                           "outdated"
                         else
                           "unresolved"
                         end
      normalize_feedback(
        kind: "review_comment",
        remote_id: remote_id,
        database_id: comment["id"],
        body: comment["body"],
        author: comment["user"],
        relevant_sha: comment["commit_id"] || comment["original_commit_id"],
        updated_at: comment["updated_at"],
        review_state: nil,
        thread_id: thread.fetch("thread_id"),
        resolution_state: resolution_state
      )
    end

    def normalize_feedback(kind:, remote_id:, database_id:, body:, author:, relevant_sha:, updated_at:,
                           review_state:, thread_id:, resolution_state:)
      remote_id = identity!(remote_id, "#{kind} identity")
      error!("#{kind} database identity is missing") unless database_id.is_a?(Integer) && database_id.positive?
      error!("#{kind} body is missing") unless body.is_a?(String)
      timestamp!(updated_at, "#{kind} updated_at")
      git_sha!(relevant_sha, "#{kind} relevant SHA") if relevant_sha
      normalized_author = classify_author(author)
      resolution_state ||= "unresolved"
      content_hash = Digest::SHA256.hexdigest(body)
      source = {
        "remote_id" => remote_id,
        "database_id" => database_id,
        "kind" => kind,
        "content_sha256" => content_hash,
        "author" => normalized_author,
        "relevant_sha" => relevant_sha,
        "updated_at" => updated_at,
        "review_state" => review_state,
        "thread_id" => thread_id,
        "resolution_state" => resolution_state,
        "remote_state" => "active"
      }
      {
        "feedback_id" => "#{kind}:#{remote_id}",
        "kind" => kind,
        "remote_id" => remote_id,
        "revision" => digest(source),
        "content_sha256" => content_hash,
        "body" => body,
        "author" => normalized_author,
        "relevant_sha" => relevant_sha,
        "thread_id" => thread_id,
        "review_state" => review_state,
        "resolution_state" => resolution_state,
        "remote_state" => "active",
        "updated_at" => updated_at,
        "previous_revision" => nil
      }
    end

    def attach_previous_revision(item, previous)
      return item unless previous

      prior_revision = previous.fetch("revision")
      item.merge("previous_revision" => item.fetch("revision") == prior_revision ? previous["previous_revision"] : prior_revision)
    end

    def deleted_item(previous, observed)
      source = {
        "feedback_id" => previous.fetch("feedback_id"),
        "previous_revision" => previous.fetch("revision"),
        "remote_state" => "deleted"
      }
      previous.merge(
        "revision" => digest(source),
        "remote_state" => "deleted",
        "updated_at" => observed,
        "previous_revision" => previous.fetch("revision")
      )
    end

    def build_ledger(items, previous, decisions, observed)
      prior = Array(previous && previous["ledger"]).to_h do |entry|
        [[entry.fetch("feedback_id"), entry.fetch("revision")], entry]
      end
      requested = parse_decisions(decisions)
      item_keys = items.to_h { |item| [[item.fetch("feedback_id"), item.fetch("revision")], true] }
      unknown = requested.keys - item_keys.keys
      error!("decision references unknown feedback revision #{unknown.first.join('@')}") if unknown.any?

      entries = prior.values.dup
      items.each do |item|
        key = [item.fetch("feedback_id"), item.fetch("revision")]
        required, reason = automatic_decision(item)
        requested_entry = requested[key]
        if required && requested_entry && requested_entry.fetch("decision") != required
          error!("feedback #{item['feedback_id']} requires automatic decision #{required}")
        end
        if requested_entry && requested_entry.fetch("decision") == "clean" && FeedbackContract.actionable?(item)
          error!("feedback #{item['feedback_id']} is an automated finding; decide fixed, declined, or not_actionable")
        end
        next if prior.key?(key) && !requested_entry

        choice = requested_entry || (required && {"decision" => required, "reason" => reason})
        next unless choice
        settles = prior[key] && prior[key]["decision"] == "finding" &&
                  FeedbackContract::SETTLED_FINDING_DECISIONS.include?(choice.fetch("decision"))
        if prior[key] && prior[key]["decision"] != choice.fetch("decision") && !settles
          error!("feedback #{item['feedback_id']} revision was already processed as #{prior[key]['decision']}")
        end
        entries.delete(prior[key]) if settles
        entry = {
          "feedback_id" => item.fetch("feedback_id"),
          "revision" => item.fetch("revision"),
          "decision" => choice.fetch("decision"),
          "reason" => choice.fetch("reason"),
          "processed_at" => settles ? observed : prior.dig(key, "processed_at") || observed
        }
        entry["candidate_sha"] = choice.fetch("candidate_sha") if choice.key?("candidate_sha")
        entries << entry
      end
      entries.sort_by { |entry| [entry.fetch("feedback_id"), entry.fetch("revision")] }
    end

    def parse_decisions(decisions)
      return {} unless decisions
      error!("feedback decisions must be a JSON object") unless decisions.is_a?(Hash)
      error!("feedback decisions require exactly a decisions array") unless decisions.keys == ["decisions"] && decisions["decisions"].is_a?(Array)
      parsed = {}
      decisions["decisions"].each do |entry|
        error!("feedback decision must be a JSON object") unless entry.is_a?(Hash)
        expected = %w[decision feedback_id reason revision]
        expected = (expected + ["candidate_sha"]).sort if entry["decision"] == "fixed"
        error!("feedback decision fields are invalid") unless entry.keys.sort == expected
        identity!(entry["feedback_id"], "feedback decision identity")
        sha256!(entry["revision"], "feedback decision revision")
        unless FeedbackContract::JUDGED_DECISIONS.include?(entry["decision"])
          error!("feedback decision must be one of #{FeedbackContract::JUDGED_DECISIONS.join(', ')}")
        end
        git_sha!(entry["candidate_sha"], "fixed feedback candidate SHA") if entry["decision"] == "fixed"
        identity!(entry["reason"], "feedback decision reason")
        key = [entry["feedback_id"], entry["revision"]]
        error!("duplicate feedback decision #{key.join('@')}") if parsed.key?(key)
        parsed[key] = entry
      end
      parsed
    end

    def automatic_decision(item)
      return ["deleted", "feedback was deleted remotely"] if item["remote_state"] == "deleted"
      return ["resolved", "review thread was resolved remotely"] if item["resolution_state"] == "resolved"
      return ["outdated", "review thread is outdated remotely"] if item["resolution_state"] == "outdated"

      case item.dig("author", "classification")
      when "unknown" then ["blocked_unknown_author", "author identity is missing, or neither a Bot nor allowlisted"]
      when "human" then ["ignored_human", "human-authored feedback is outside the automated gate"]
      else
        return ["no_content", "automated feedback has no textual content"] if item["body"].strip.empty?

        [nil, nil]
      end
    end

    def derive_overall(items, ledger)
      decisions = ledger.to_h { |entry| [[entry.fetch("feedback_id"), entry.fetch("revision")], entry.fetch("decision")] }
      values = items.map { |item| decisions[[item.fetch("feedback_id"), item.fetch("revision")]] }
      return "blocked" if values.include?("blocked_unknown_author")
      return "pending" if values.any?(&:nil?)
      return "findings" if values.include?("finding")

      "clean"
    end

    def classify_author(author)
      id = author && author["node_id"] || author && author["id"]
      login = author && author["login"]
      type = author && (author["type"] || author["__typename"])
      allowed = @author_policy.fetch("authors").find do |candidate|
        candidate.values_at("id", "login", "type") == [id, login, type]
      end
      complete = id.is_a?(String) && !id.empty? && login.is_a?(String) && !login.empty?
      # Only a GitHub App acts as a Bot, so any complete Bot identity is automated. The policy
      # lists automation that posts as a User account.
      classification = if allowed || (complete && type == "Bot")
                         "automated"
                       elsif complete && type == "User"
                         "human"
                       else
                         "unknown"
                       end
      {"id" => id, "login" => login, "type" => type, "classification" => classification}
    end

    def validate_pr!(pull_request, candidate_sha)
      error!("pull request head moved to #{pull_request.dig('head', 'sha')}") unless pull_request.dig("head", "sha") == candidate_sha
      error!("pull request is not open") unless pull_request["state"] == "open"
    end

    def validate_previous_identity!(previous, repository, pull_request, baseline_at)
      comparisons = {
        "repository" => [previous["repository_id"], repository["node_id"]],
        "pull request" => [previous["pull_request_id"], pull_request["node_id"]],
        "PR number" => [previous["pr_number"], pull_request["number"]],
        "baseline" => [previous["baseline_at"], baseline_at],
        "author policy" => [previous["author_policy_version"], @author_policy["author_policy_version"]]
      }
      changed = comparisons.select { |_label, pair| pair[0] != pair[1] }.keys
      error!("previous feedback identity changed: #{changed.join(', ')}") if changed.any?
    end

    def validate_author_policy!
      unless @author_policy.is_a?(Hash) && @author_policy.keys.sort == %w[author_policy_version authors] &&
             @author_policy["author_policy_version"].is_a?(Integer) && @author_policy["author_policy_version"].positive? &&
             @author_policy["authors"].is_a?(Array) && @author_policy["authors"].any?
        error!("automated feedback author policy is invalid")
      end
      identities = {}
      @author_policy["authors"].each do |author|
        error!("automated feedback author policy entry is invalid") unless author.is_a?(Hash) && author.keys.sort == %w[id login type]
        %w[id login type].each { |field| identity!(author[field], "automated feedback author #{field}") }
        key = author.values_at("id", "login", "type")
        error!("duplicate automated feedback author") if identities.key?(key)
        identities[key] = true
      end
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def observed_at
      @clock.call.utc.iso8601(6)
    end

    def repository_name!(value)
      error!("repository must be owner/name") unless value.to_s.match?(PrCiContract::REPOSITORY_NAME)
    end

    def positive_integer!(value, label)
      number = Integer(value, exception: false)
      error!("#{label} is invalid") unless number&.positive?
      number
    end

    def identity!(value, label)
      error!("#{label} is missing") unless value.is_a?(String) && !value.empty? && !value.match?(/[\r\n]/)
      value
    end

    def uuid!(value, label)
      error!("#{label} is invalid") unless value.to_s.match?(EventLog::UUID)
    end

    def git_sha!(value, label)
      error!("#{label} is invalid") unless value.to_s.match?(EventLog::GIT_SHA)
    end

    def sha256!(value, label)
      error!("#{label} is invalid") unless value.to_s.match?(FeedbackContract::SHA256)
    end

    def timestamp!(value, label)
      parsed = Time.iso8601(value.to_s)
      error!("#{label} must be UTC") unless parsed.utc_offset.zero? && value.end_with?("Z")
    rescue ArgumentError
      error!("#{label} is invalid")
    end

    def error!(message)
      raise AdapterError, message
    end
  end
end
