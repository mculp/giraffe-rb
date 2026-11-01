#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "event_log"

module PrGraph
  class PrCiContract
    class PrCiError < ContractError; end

    PUBLISH_KEYS = %w[action observed_at pull_request repository schema_version].freeze
    REPOSITORY_KEYS = %w[id name_with_owner].freeze
    PULL_REQUEST_KEYS = %w[base_ref head_ref head_sha id is_draft number state updated_at url].freeze
    CI_KEYS = %w[authoritative_run_ids candidate_sha checks observed_at overall pr_number pull_request_id repository_id schema_version wake_id].freeze
    CHECK_KEYS = %w[attempt completed_at details_url head_sha logical_id provider provider_identity revision run_id started_at state supersedes_run_id terminal].freeze
    CHECK_STATES = %w[pending passed failed cancelled].freeze
    REPOSITORY_NAME = %r{\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}\z}.freeze

    def validate_publish!(manifest, artifact: nil, pr: nil, candidate_sha: nil)
      object!(manifest, "publish manifest")
      exact_keys!(manifest, PUBLISH_KEYS, "publish manifest")
      error!("publish schema_version must be 1") unless manifest["schema_version"] == 1
      error!("publish action is invalid") unless %w[created adopted reconciled].include?(manifest["action"])
      timestamp!(manifest["observed_at"], "publish observed_at")

      repository = manifest["repository"]
      object!(repository, "publish repository")
      exact_keys!(repository, REPOSITORY_KEYS, "publish repository")
      identity!(repository["id"], "repository id")
      unless repository["name_with_owner"].to_s.match?(REPOSITORY_NAME)
        error!("repository name_with_owner is invalid")
      end

      pull_request = manifest["pull_request"]
      object!(pull_request, "publish pull_request")
      exact_keys!(pull_request, PULL_REQUEST_KEYS, "publish pull_request")
      identity!(pull_request["id"], "pull request id")
      error!("pull request number is invalid") unless pull_request["number"].is_a?(Integer) && pull_request["number"].positive?
      %w[url base_ref head_ref].each { |field| identity!(pull_request[field], "pull request #{field}") }
      git_sha!(pull_request["head_sha"], "pull request head_sha")
      error!("pull request is_draft must be a boolean") unless [true, false].include?(pull_request["is_draft"])
      error!("published pull request must be open") unless pull_request["state"] == "open"
      timestamp!(pull_request["updated_at"], "pull request updated_at")

      expected_sha = candidate_sha || artifact && artifact["candidate_sha"]
      if expected_sha && pull_request["head_sha"] != expected_sha
        error!("publish manifest head SHA does not match the candidate")
      end
      if artifact && artifact["input_sha"] != pull_request["head_sha"]
        error!("publish artifact input SHA does not match the pull request")
      end
      if pr && pull_request["number"] != pr.to_i
        error!("publish manifest PR number does not match completion")
      end
      manifest
    end

    def validate_ci!(manifest, artifact: nil, expected_pass: nil)
      object!(manifest, "CI manifest")
      exact_keys!(manifest, CI_KEYS, "CI manifest")
      error!("CI schema_version must be 1") unless manifest["schema_version"] == 1
      timestamp!(manifest["observed_at"], "CI observed_at")
      identity!(manifest["repository_id"], "CI repository_id")
      identity!(manifest["pull_request_id"], "CI pull_request_id")
      error!("CI pr_number is invalid") unless manifest["pr_number"].is_a?(Integer) && manifest["pr_number"].positive?
      git_sha!(manifest["candidate_sha"], "CI candidate_sha")
      uuid!(manifest["wake_id"], "CI wake_id")
      error!("CI overall state is invalid") unless %w[pending passed failed].include?(manifest["overall"])
      error!("CI checks must be an array") unless manifest["checks"].is_a?(Array)
      error!("CI authoritative_run_ids must be an array") unless manifest["authoritative_run_ids"].is_a?(Array)

      runs = {}
      groups = Hash.new { |hash, key| hash[key] = [] }
      manifest["checks"].each_with_index do |check, index|
        validate_check!(check, manifest["candidate_sha"], index)
        error!("duplicate CI run_id #{check['run_id']}") if runs.key?(check["run_id"])

        runs[check["run_id"]] = check
        groups[check["logical_id"]] << check
      end

      authoritative = groups.values.map do |checks|
        ordered = checks.sort_by { |check| check["attempt"] }
        ordered.each_with_index do |check, index|
          error!("CI attempts must be contiguous for #{check['logical_id']}") unless check["attempt"] == index + 1
          expected_parent = index.zero? ? nil : ordered[index - 1]["run_id"]
          unless check["supersedes_run_id"] == expected_parent
            error!("CI rerun lineage is broken for #{check['run_id']}")
          end
        end
        ordered.last
      end
      authoritative_ids = authoritative.map { |check| check["run_id"] }.sort
      unless manifest["authoritative_run_ids"].uniq.sort == authoritative_ids
        error!("CI authoritative run identities do not match rerun lineage")
      end

      derived = if authoritative.empty? || authoritative.any? { |check| check["state"] == "pending" }
                  "pending"
                elsif authoritative.any? { |check| %w[failed cancelled].include?(check["state"]) }
                  "failed"
                else
                  "passed"
                end
      error!("CI overall state does not match authoritative checks") unless manifest["overall"] == derived
      error!("CI cannot complete before checks pass") if expected_pass == true && derived != "passed"
      error!("CI failure requires an authoritative failed check") if expected_pass == false && derived != "failed"

      if artifact
        error!("CI artifact candidate does not match its content") unless artifact["candidate_sha"] == manifest["candidate_sha"]
        error!("CI artifact input SHA does not match its content") unless artifact["input_sha"] == manifest["candidate_sha"]
        error!("CI artifact wake does not match its content") unless artifact["wake_id"] == manifest["wake_id"]
      end
      manifest
    end

    private

    def validate_check!(check, candidate_sha, index)
      object!(check, "CI check #{index + 1}")
      exact_keys!(check, CHECK_KEYS, "CI check #{index + 1}")
      %w[provider provider_identity logical_id run_id revision].each do |field|
        identity!(check[field], "CI check #{field}")
      end
      error!("CI check attempt is invalid") unless check["attempt"].is_a?(Integer) && check["attempt"].positive?
      git_sha!(check["head_sha"], "CI check head_sha")
      error!("stale CI status does not match the candidate SHA") unless check["head_sha"] == candidate_sha
      error!("CI check state is invalid") unless CHECK_STATES.include?(check["state"])
      expected_terminal = check["state"] != "pending"
      error!("CI check terminal flag disagrees with state") unless check["terminal"] == expected_terminal
      if check["supersedes_run_id"]
        identity!(check["supersedes_run_id"], "CI supersedes_run_id")
      end
      timestamp!(check["started_at"], "CI check started_at") if check["started_at"]
      timestamp!(check["completed_at"], "CI check completed_at") if check["completed_at"]
      identity!(check["details_url"], "CI check details_url") if check["details_url"]
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

    def timestamp!(value, label)
      identity!(value, label)
      parsed = Time.iso8601(value)
      error!("#{label} must be UTC") unless parsed.utc_offset.zero? && value.end_with?("Z")
    rescue ArgumentError
      error!("#{label} is invalid")
    end

    def error!(message)
      raise PrCiError, message
    end
  end
end
