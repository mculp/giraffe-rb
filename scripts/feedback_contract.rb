#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "event_log"

module PrGraph
  class FeedbackContract
    class FeedbackError < ContractError; end

    MANIFEST_KEYS = %w[author_policy_version baseline_at candidate_sha feedback ledger observed_at overall pr_number pull_request_id repository_id schema_version threads wake_id].freeze
    FEEDBACK_KEYS = %w[author body content_sha256 feedback_id kind previous_revision relevant_sha remote_id remote_state resolution_state revision review_state thread_id updated_at].freeze
    AUTHOR_KEYS = %w[classification id login type].freeze
    THREAD_KEYS = %w[comment_ids content_sha256 is_outdated is_resolved line path relevant_sha revision thread_id updated_at].freeze
    LEDGER_KEYS = %w[decision feedback_id processed_at reason revision].freeze
    OPTIONAL_LEDGER_KEYS = %w[candidate_sha].freeze
    KINDS = %w[issue_comment review review_comment].freeze
    AUTHOR_CLASSIFICATIONS = %w[automated human unknown].freeze
    REMOTE_STATES = %w[active deleted].freeze
    RESOLUTION_STATES = %w[unresolved resolved outdated not_applicable].freeze
    JUDGED_DECISIONS = %w[clean finding fixed declined not_actionable].freeze
    SETTLED_FINDING_DECISIONS = %w[fixed declined not_actionable].freeze
    DECISIONS = (JUDGED_DECISIONS + %w[ignored_human no_content resolved outdated deleted blocked_unknown_author]).freeze
    OVERALL_STATES = %w[pending clean findings blocked].freeze
    SHA256 = /\A[0-9a-f]{64}\z/.freeze

    def validate!(manifest, artifact: nil, expected_pass: nil)
      object!(manifest, "feedback manifest")
      exact_keys!(manifest, MANIFEST_KEYS, "feedback manifest")
      error!("feedback schema_version must be 1") unless manifest["schema_version"] == 1
      error!("feedback author_policy_version must be a positive integer") unless manifest["author_policy_version"].is_a?(Integer) && manifest["author_policy_version"].positive?
      timestamp!(manifest["baseline_at"], "feedback baseline_at")
      timestamp!(manifest["observed_at"], "feedback observed_at")
      identity!(manifest["repository_id"], "feedback repository_id")
      identity!(manifest["pull_request_id"], "feedback pull_request_id")
      error!("feedback pr_number is invalid") unless manifest["pr_number"].is_a?(Integer) && manifest["pr_number"].positive?
      git_sha!(manifest["candidate_sha"], "feedback candidate_sha")
      uuid!(manifest["wake_id"], "feedback wake_id")
      error!("feedback overall state is invalid") unless OVERALL_STATES.include?(manifest["overall"])
      error!("feedback must be an array") unless manifest["feedback"].is_a?(Array)
      error!("feedback threads must be an array") unless manifest["threads"].is_a?(Array)
      error!("feedback ledger must be an array") unless manifest["ledger"].is_a?(Array)

      threads = manifest["threads"].to_h do |thread|
        validate_thread!(thread)
        [thread.fetch("thread_id"), thread]
      end
      error!("duplicate feedback thread identity") unless threads.length == manifest["threads"].length

      ledger = manifest["ledger"].to_h do |entry|
        validate_ledger!(entry)
        [[entry.fetch("feedback_id"), entry.fetch("revision")], entry]
      end
      error!("duplicate feedback ledger identity and revision") unless ledger.length == manifest["ledger"].length

      identities = {}
      manifest["feedback"].each do |item|
        validate_feedback!(item, threads)
        error!("duplicate feedback identity #{item['feedback_id']}") if identities.key?(item["feedback_id"])
        identities[item["feedback_id"]] = item
      end

      ledger.each_key do |key|
        error!("feedback ledger references an unknown identity #{key.first}") unless identities.key?(key.first)
      end
      identities.each_value do |item|
        entry = ledger[[item.fetch("feedback_id"), item.fetch("revision")]]
        validate_decision_for!(item, entry)
      end

      derived = derive_overall(identities.values, ledger)
      if derived == "clean"
        undecided = identities.values.select do |item|
          entry = ledger[[item.fetch("feedback_id"), item.fetch("revision")]]
          self.class.actionable?(item) && entry["decision"] == "clean"
        end
        if undecided.any?
          error!("feedback overall clean requires a fixed, declined, or not_actionable decision on " \
                 "#{undecided.map { |item| item['feedback_id'] }.join(', ')}")
        end
      end
      error!("feedback overall state does not match the processing ledger") unless manifest["overall"] == derived
      error!("automated feedback cannot complete before it is clean") if expected_pass == true && derived != "clean"
      error!("automated feedback failure requires a processed finding") if expected_pass == false && derived != "findings"

      if artifact
        error!("feedback artifact candidate does not match its content") unless artifact["candidate_sha"] == manifest["candidate_sha"]
        error!("feedback artifact input SHA does not match its content") unless artifact["input_sha"] == manifest["candidate_sha"]
        error!("feedback artifact wake does not match its content") unless artifact["wake_id"] == manifest["wake_id"]
      end
      manifest
    end

    # An automated inline comment, or an automated review with a body, carries findings that need a
    # fixed, declined, or not_actionable decision before the gate is clean.
    def self.actionable?(item)
      item.dig("author", "classification") == "automated" && item["remote_state"] == "active" &&
        %w[review review_comment].include?(item["kind"]) && !item["body"].strip.empty?
    end

    private

    def validate_feedback!(item, threads)
      object!(item, "feedback item")
      exact_keys!(item, FEEDBACK_KEYS, "feedback item")
      identity!(item["feedback_id"], "feedback identity")
      identity!(item["remote_id"], "feedback remote identity")
      error!("feedback kind is invalid") unless KINDS.include?(item["kind"])
      sha256!(item["revision"], "feedback revision")
      sha256!(item["content_sha256"], "feedback content_sha256")
      error!("feedback body must be a string") unless item["body"].is_a?(String)
      object!(item["author"], "feedback author")
      exact_keys!(item["author"], AUTHOR_KEYS, "feedback author")
      error!("feedback author classification is invalid") unless AUTHOR_CLASSIFICATIONS.include?(item.dig("author", "classification"))
      if item.dig("author", "classification") == "unknown"
        %w[id login type].each do |field|
          value = item.dig("author", field)
          error!("unknown feedback author #{field} must be a string or null") unless value.nil? || value.is_a?(String)
        end
      else
        %w[id login type].each { |field| identity!(item.dig("author", field), "feedback author #{field}") }
      end
      git_sha!(item["relevant_sha"], "feedback relevant_sha") if item["relevant_sha"]
      error!("feedback remote state is invalid") unless REMOTE_STATES.include?(item["remote_state"])
      error!("feedback resolution state is invalid") unless RESOLUTION_STATES.include?(item["resolution_state"])
      timestamp!(item["updated_at"], "feedback updated_at")
      sha256!(item["previous_revision"], "feedback previous_revision") if item["previous_revision"]
      if item["kind"] == "review_comment"
        identity!(item["thread_id"], "review comment thread identity")
        error!("review comment references an unknown thread") unless threads.key?(item["thread_id"])
      elsif item["thread_id"]
        error!("only review comments may carry a thread identity")
      end
      if item["kind"] == "review"
        identity!(item["review_state"], "review state")
      elsif item["review_state"]
        error!("only reviews may carry review_state")
      end
    end

    def validate_thread!(thread)
      object!(thread, "feedback thread")
      exact_keys!(thread, THREAD_KEYS, "feedback thread")
      identity!(thread["thread_id"], "feedback thread identity")
      sha256!(thread["revision"], "feedback thread revision")
      sha256!(thread["content_sha256"], "feedback thread content_sha256")
      error!("feedback thread is_resolved must be boolean") unless [true, false].include?(thread["is_resolved"])
      error!("feedback thread is_outdated must be boolean") unless [true, false].include?(thread["is_outdated"])
      error!("feedback thread path must be a string or null") unless thread["path"].nil? || thread["path"].is_a?(String)
      error!("feedback thread line must be an integer or null") unless thread["line"].nil? || thread["line"].is_a?(Integer)
      error!("feedback thread comment_ids must be a non-empty array") unless thread["comment_ids"].is_a?(Array) && thread["comment_ids"].any?
      thread["comment_ids"].each { |id| identity!(id, "feedback thread comment identity") }
      error!("feedback thread contains duplicate comment identities") unless thread["comment_ids"].uniq == thread["comment_ids"]
      git_sha!(thread["relevant_sha"], "feedback thread relevant_sha") if thread["relevant_sha"]
      timestamp!(thread["updated_at"], "feedback thread updated_at")
    end

    def validate_ledger!(entry)
      object!(entry, "feedback ledger entry")
      exact_keys!(entry.slice(*(entry.keys - OPTIONAL_LEDGER_KEYS)), LEDGER_KEYS, "feedback ledger entry")
      identity!(entry["feedback_id"], "feedback ledger identity")
      sha256!(entry["revision"], "feedback ledger revision")
      error!("feedback ledger decision is invalid") unless DECISIONS.include?(entry["decision"])
      identity!(entry["reason"], "feedback ledger reason")
      timestamp!(entry["processed_at"], "feedback ledger processed_at")
      if entry["decision"] == "fixed"
        git_sha!(entry["candidate_sha"], "fixed feedback candidate_sha")
      elsif entry.key?("candidate_sha")
        error!("only fixed feedback may carry candidate_sha")
      end
    end

    def validate_decision_for!(item, entry)
      classification = item.dig("author", "classification")
      required = if item["remote_state"] == "deleted"
                   "deleted"
                 elsif item["resolution_state"] == "resolved"
                   "resolved"
                 elsif item["resolution_state"] == "outdated"
                   "outdated"
                 elsif classification == "unknown"
                   "blocked_unknown_author"
                 elsif classification == "human"
                   "ignored_human"
                 elsif item["body"].strip.empty?
                   "no_content"
                 end
      if required
        error!("feedback #{item['feedback_id']} requires ledger decision #{required}") unless entry && entry["decision"] == required
      elsif entry && !JUDGED_DECISIONS.include?(entry["decision"])
        error!("active automated feedback requires a #{JUDGED_DECISIONS.join(', ')} decision")
      end
    end

    def derive_overall(items, ledger)
      decisions = items.map { |item| ledger[[item.fetch("feedback_id"), item.fetch("revision")]]&.fetch("decision") }
      return "blocked" if decisions.include?("blocked_unknown_author")
      return "pending" if decisions.any?(&:nil?)
      return "findings" if decisions.include?("finding")

      "clean"
    end

    def object!(value, label)
      error!("#{label} must be a JSON object") unless value.is_a?(Hash)
    end

    def exact_keys!(value, expected, label)
      missing = expected - value.keys
      unknown = value.keys - expected
      error!("#{label} missing field(s): #{missing.join(', ')}") if missing.any?
      error!("#{label} has unknown field(s): #{unknown.join(', ')}") if unknown.any?
    end

    def identity!(value, label)
      error!("#{label} is missing") unless value.is_a?(String) && !value.empty? && !value.match?(/[\r\n]/)
    end

    def uuid!(value, label)
      error!("#{label} is invalid") unless value.is_a?(String) && value.match?(EventLog::UUID)
    end

    def git_sha!(value, label)
      error!("#{label} is invalid") unless value.is_a?(String) && value.match?(EventLog::GIT_SHA)
    end

    def sha256!(value, label)
      error!("#{label} is invalid") unless value.is_a?(String) && value.match?(SHA256)
    end

    def timestamp!(value, label)
      identity!(value, label)
      parsed = Time.iso8601(value)
      error!("#{label} must be UTC") unless parsed.utc_offset.zero? && value.end_with?("Z")
    rescue ArgumentError
      error!("#{label} is invalid")
    end

    def error!(message)
      raise FeedbackError, message
    end
  end
end
