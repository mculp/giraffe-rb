#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "event_log"

module PrGraph
  class SeedContract
    class SeedError < ContractError; end

    PLAN_KEYS = %w[candidate_sha run_id scenarios schema_version target].freeze
    TARGET_KEYS = %w[kind locator].freeze
    SCENARIO_KEYS = %w[description id ruby].freeze
    MANIFEST_KEYS = %w[candidate_sha cleanup error observed_at run_id runner scenarios schema_version script_sha256 status target].freeze
    RUNNER_KEYS = %w[command exit_status invocation_count stderr_sha256 stdout_sha256].freeze
    RESULT_KEYS = %w[description id idempotency_key mutations status].freeze
    MUTATION_KEYS = %w[action changed cleanup created current identity kind previous].freeze
    CLEANUP_KEYS = %w[actions required residuals status].freeze
    CLEANUP_ACTION_KEYS = %w[identity instruction kind status].freeze
    ERROR_KEYS = %w[class message].freeze

    PLAN_TARGETS = %w[local review_app staging].freeze
    MANIFEST_STATUSES = %w[prepared no_op running succeeded failed uncertain].freeze
    SCENARIO_STATUSES = %w[pending skipped succeeded failed rolled_back].freeze
    CLEANUP_STATUSES = %w[not_required available restored incomplete unknown].freeze
    ACTION_STATUSES = %w[not_needed pending rolled_back restored failed unknown].freeze
    MUTATION_ACTIONS = %w[created reused updated unchanged enabled already_enabled external].freeze
    SCENARIO_ID = /\A[a-z0-9][a-z0-9._-]{0,79}\z/.freeze
    LABEL = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/.freeze
    SHA256 = /\A[0-9a-f]{64}\z/.freeze

    def validate_plan!(plan)
      object!(plan, "seed plan")
      exact_keys!(plan, PLAN_KEYS, "seed plan")
      error!("seed plan schema_version must be 1") unless plan["schema_version"] == 1
      uuid!(plan["run_id"], "seed run_id")
      git_sha!(plan["candidate_sha"], "seed candidate_sha")
      validate_target!(plan["target"])
      error!("seed scenarios must be an array") unless plan["scenarios"].is_a?(Array)

      ids = {}
      plan["scenarios"].each_with_index do |scenario, index|
        object!(scenario, "seed scenario #{index + 1}")
        exact_keys!(scenario, SCENARIO_KEYS, "seed scenario #{index + 1}")
        id = scenario["id"]
        error!("seed scenario id is invalid") unless id.is_a?(String) && id.match?(SCENARIO_ID)
        error!("duplicate seed scenario id #{id}") if ids.key?(id)
        ids[id] = true
        identity!(scenario["description"], "seed scenario description")
        ruby = scenario["ruby"]
        unless ruby.nil? || ruby.is_a?(String) && !ruby.strip.empty?
          error!("seed scenario ruby must be null or a non-empty string")
        end
      end
      plan
    end

    def validate_manifest!(manifest, plan: nil)
      object!(manifest, "seed manifest")
      exact_keys!(manifest, MANIFEST_KEYS, "seed manifest")
      error!("seed manifest schema_version must be 1") unless manifest["schema_version"] == 1
      uuid!(manifest["run_id"], "seed manifest run_id")
      git_sha!(manifest["candidate_sha"], "seed manifest candidate_sha")
      sha256!(manifest["script_sha256"], "seed manifest script_sha256")
      timestamp!(manifest["observed_at"], "seed manifest observed_at")
      validate_target!(manifest["target"])
      error!("seed manifest status is invalid") unless MANIFEST_STATUSES.include?(manifest["status"])
      validate_runner!(manifest["runner"])
      validate_cleanup!(manifest["cleanup"])
      validate_error!(manifest["error"])
      validate_state!(manifest)

      if plan
        validate_plan!(plan)
        %w[run_id candidate_sha target].each do |field|
          error!("seed manifest #{field} does not match its plan") unless manifest[field] == plan[field]
        end
        expected_ids = plan["scenarios"].map { |scenario| scenario.fetch("id") }
        actual_ids = manifest["scenarios"].map { |scenario| scenario.fetch("id") }
        error!("seed manifest scenarios do not match its plan") unless actual_ids == expected_ids
        validate_plan_states!(manifest, plan)
      end
      manifest
    end

    def active_scenarios(plan)
      validate_plan!(plan)
      plan.fetch("scenarios").reject { |scenario| scenario["ruby"].nil? }
    end

    def stable_key(run_id, scenario_id, label)
      uuid!(run_id, "seed run_id")
      error!("seed scenario id is invalid") unless scenario_id.is_a?(String) && scenario_id.match?(SCENARIO_ID)
      error!("seed key label is invalid") unless label.is_a?(String) && label.match?(LABEL)

      "prg-#{Digest::SHA256.hexdigest([run_id.downcase, scenario_id, label].join("\0"))[0, 28]}"
    end

    private

    def validate_target!(target)
      object!(target, "seed target")
      exact_keys!(target, TARGET_KEYS, "seed target")
      error!("seed target kind is invalid") unless PLAN_TARGETS.include?(target["kind"])
      identity!(target["locator"], "seed target locator")
    end

    def validate_runner!(runner)
      object!(runner, "seed runner")
      exact_keys!(runner, RUNNER_KEYS, "seed runner")
      error!("seed runner command must be an array") unless runner["command"].is_a?(Array)
      runner["command"].each { |part| identity!(part, "seed runner command part") }
      unless runner["exit_status"].nil? || runner["exit_status"].is_a?(Integer)
        error!("seed runner exit_status must be an integer or null")
      end
      count = runner["invocation_count"]
      error!("seed runner invocation_count must be zero or one") unless [0, 1].include?(count)
      %w[stdout_sha256 stderr_sha256].each do |field|
        sha256!(runner[field], "seed runner #{field}") if runner[field]
      end
    end

    def validate_results!(results)
      error!("seed manifest scenarios must be an array") unless results.is_a?(Array)
      identities = {}
      results.each_with_index do |result, index|
        object!(result, "seed result #{index + 1}")
        exact_keys!(result, RESULT_KEYS, "seed result #{index + 1}")
        id = result["id"]
        error!("seed result id is invalid") unless id.is_a?(String) && id.match?(SCENARIO_ID)
        identity!(result["description"], "seed result description")
        identity!(result["idempotency_key"], "seed result idempotency_key")
        unless result["idempotency_key"] == scenario_key(result)
          error!("seed result idempotency key is not derived from run and scenario identity")
        end
        error!("seed result status is invalid") unless SCENARIO_STATUSES.include?(result["status"])
        error!("seed mutations must be an array") unless result["mutations"].is_a?(Array)
        result["mutations"].each do |mutation|
          validate_mutation!(mutation)
          key = [id, mutation["kind"], mutation["identity"]]
          error!("duplicate seed mutation identity #{key.join(':')}") if identities.key?(key)
          identities[key] = true
        end
      end
    end

    def validate_state!(manifest)
      @manifest_run_id = manifest.fetch("run_id")
      validate_results!(manifest.fetch("scenarios"))

      status = manifest.fetch("status")
      runner = manifest.fetch("runner")
      error = manifest["error"]
      if %w[prepared no_op].include?(status)
        error!("unexecuted seed manifest cannot record a runner invocation") unless runner["invocation_count"].zero?
        error!("unexecuted seed manifest cannot carry an error") if error
      else
        error!("executed seed manifest must record exactly one runner invocation") unless runner["invocation_count"] == 1
      end
      error!("successful seed manifest cannot carry an error") if status == "succeeded" && error
      error!("failed or uncertain seed manifest must carry an error") if %w[failed uncertain].include?(status) && error.nil?
      if status == "no_op"
        error!("no-op seed manifest cannot require cleanup") if manifest.dig("cleanup", "required")
        error!("no-op seed manifest has active scenarios") if manifest["scenarios"].any? { |result| result["status"] != "skipped" }
      end
      error!("successful seed must have a zero runner exit status") if status == "succeeded" && runner["exit_status"] != 0
      validate_cleanup_state!(manifest)
    ensure
      @manifest_run_id = nil
    end

    def validate_plan_states!(manifest, plan)
      active_results = []
      plan.fetch("scenarios").zip(manifest.fetch("scenarios")).each do |scenario, result|
        if scenario["ruby"].nil?
          error!("non-mutating seed scenario must remain skipped") unless result["status"] == "skipped"
        else
          active_results << result
        end
      end

      case manifest["status"]
      when "prepared", "running"
        error!("unresolved seed scenario state is inconsistent") unless active_results.all? { |result| result["status"] == "pending" }
      when "uncertain"
        allowed = %w[pending succeeded failed rolled_back skipped]
        error!("uncertain seed contains an invalid scenario state") unless (active_results.map { |result| result["status"] } - allowed).empty?
      when "succeeded"
        error!("successful seed has an incomplete scenario") unless active_results.all? { |result| result["status"] == "succeeded" }
      when "failed"
        states = active_results.map { |result| result["status"] }
        error!("failed seed must identify exactly one failed scenario") unless states.count("failed") == 1
        error!("failed seed contains an invalid scenario state") unless (states - %w[rolled_back failed skipped]).empty?
      end
    end

    def validate_cleanup_state!(manifest)
      cleanup = manifest.fetch("cleanup")
      pending = cleanup.fetch("actions").any? { |action| action["status"] == "pending" }
      case manifest["status"]
      when "prepared", "running", "no_op"
        expected = {"required" => false, "status" => "not_required", "actions" => [], "residuals" => []}
        error!("unexecuted seed cleanup state is inconsistent") unless cleanup == expected
      when "succeeded"
        error!("successful seed cleanup requirement is inconsistent") unless cleanup["required"] == pending
        expected = pending ? "available" : "not_required"
        error!("successful seed cleanup status is inconsistent") unless cleanup["status"] == expected
        error!("successful seed cannot contain cleanup residuals") if cleanup["residuals"].any?
      when "failed"
        error!("failed seed cannot leave planned cleanup pending") if pending || cleanup["required"]
        expected = cleanup["residuals"].any? ? "incomplete" : cleanup["actions"].any? ? "restored" : "not_required"
        error!("failed seed cleanup status is inconsistent") unless cleanup["status"] == expected
      when "uncertain"
        error!("uncertain seed must require reconciliation") unless cleanup["required"] && cleanup["status"] == "unknown"
        error!("uncertain seed must report a residual") if cleanup["residuals"].empty?
      end
    end

    def scenario_key(result)
      @manifest_run_id && stable_key(@manifest_run_id, result["id"], "scenario")
    end

    def validate_mutation!(mutation)
      object!(mutation, "seed mutation")
      exact_keys!(mutation, MUTATION_KEYS, "seed mutation")
      %w[kind identity cleanup].each { |field| identity!(mutation[field], "seed mutation #{field}") }
      error!("seed mutation action is invalid") unless MUTATION_ACTIONS.include?(mutation["action"])
      error!("seed mutation created must be boolean") unless [true, false].include?(mutation["created"])
      error!("seed mutation changed must be boolean") unless [true, false].include?(mutation["changed"])
    end

    def validate_cleanup!(cleanup)
      object!(cleanup, "seed cleanup")
      exact_keys!(cleanup, CLEANUP_KEYS, "seed cleanup")
      error!("seed cleanup required must be boolean") unless [true, false].include?(cleanup["required"])
      error!("seed cleanup status is invalid") unless CLEANUP_STATUSES.include?(cleanup["status"])
      error!("seed cleanup actions must be an array") unless cleanup["actions"].is_a?(Array)
      error!("seed cleanup residuals must be an array") unless cleanup["residuals"].is_a?(Array)
      cleanup["residuals"].each { |value| identity!(value, "seed cleanup residual") }
      cleanup["actions"].each do |action|
        object!(action, "seed cleanup action")
        exact_keys!(action, CLEANUP_ACTION_KEYS, "seed cleanup action")
        %w[identity instruction kind].each { |field| identity!(action[field], "seed cleanup action #{field}") }
        error!("seed cleanup action status is invalid") unless ACTION_STATUSES.include?(action["status"])
      end
    end

    def validate_error!(error)
      return if error.nil?

      object!(error, "seed error")
      exact_keys!(error, ERROR_KEYS, "seed error")
      %w[class message].each { |field| identity!(error[field], "seed error #{field}") }
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
      raise SeedError, message
    end
  end
end
