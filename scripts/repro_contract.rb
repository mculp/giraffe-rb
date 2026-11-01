#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "event_log"

module PrGraph
  # Validates the REPRODUCE node's repro_report and the PLAN obligations it creates.
  #
  # A bug ticket's reported steps are run against the base before anything is planned, so the plan
  # starts from the code path the steps actually take rather than the one the ticket implies.
  class ReproContract
    class ReproError < ContentError; end

    STATUSES = %w[reproduced not_reproduced not_applicable].freeze
    FIELDS = {
      "reproduced" => %w[status base_sha steps expected observed code_path evidence clause_ids rerun],
      "not_reproduced" => %w[status base_sha steps expected observed evidence reason],
      "not_applicable" => %w[status base_sha reason]
    }.freeze
    SHA = /\A[0-9a-f]{40}\z/

    def validate_report!(report, clause_ids:, input_sha:)
      error!("repro report must be a JSON object") unless report.is_a?(Hash)
      status = report["status"]
      error!("repro report status must be one of #{STATUSES.join(', ')}") unless STATUSES.include?(status)
      require_exact_fields!(report, FIELDS.fetch(status), "#{status} repro report")
      error!("repro report base_sha must be a full commit SHA") unless report["base_sha"].to_s.match?(SHA)
      error!("repro report base_sha must match the artifact input SHA") unless report["base_sha"] == input_sha

      require_text!(report["reason"], "repro report reason") if report.key?("reason")
      return report if status == "not_applicable"

      require_nonempty_array!(report["steps"], "repro report steps").each_with_index do |step, index|
        require_text!(step, "repro step #{index + 1}")
      end
      require_text!(report["expected"], "repro report expected")
      require_text!(report["observed"], "repro report observed")
      require_nonempty_array!(report["evidence"], "repro report evidence").each_with_index do |item, index|
        label = "repro evidence #{index + 1}"
        require_exact_fields!(item, %w[command excerpt], label)
        require_text!(item["command"], "#{label} command")
        require_text!(item["excerpt"], "#{label} excerpt")
      end
      return report if status == "not_reproduced"

      require_nonempty_array!(report["code_path"], "repro report code_path").each_with_index do |entry, index|
        require_text!(entry, "repro code_path #{index + 1}")
      end
      require_text!(report["rerun"], "repro report rerun")
      require_nonempty_array!(report["clause_ids"], "repro report clause_ids").each do |id|
        require_text!(id, "repro clause id")
        error!("repro report references unknown outcome clause #{id}") unless clause_ids.include?(id)
      end
      report
    end

    # The plan must start from what the repro observed, and every clause the repro exercised must be
    # proven again at VERIFY by re-running it against the candidate.
    def validate_plan!(report, implementation_plan, test_plan)
      return if report.fetch("status") == "not_applicable"

      cited = implementation_plan.fetch("steps").any? do |step|
        step.fetch("evidence").any? { |item| item["kind"] == "reproduction" && item["ref"] == "repro_report" }
      end
      error!("PLAN must cite the repro_report as reproduction evidence") unless cited
      return if report.fetch("status") == "not_reproduced"

      planned = test_plan.fetch("coverage").each_with_object({}) { |item, map| map[item["outcome_id"]] = item }
      report.fetch("clause_ids").each do |id|
        item = planned[id]
        next if item && item["status"] == "planned" && item["planned_node"] == "VERIFY"

        error!("repro clause #{id} must be planned for VERIFY so the repro is re-run against the candidate")
      end
    end

    # A reproduced bug leaves a committed regression spec behind: BUILD writes it from the repro, and a
    # green VERIFY records running it on the base, where it must fail, and on the candidate, where it
    # must pass. That is the proof the spec tests the reported bug and the candidate fixes it.
    def validate_regression!(report, verification, candidate_sha:, changed_paths:, strict: true)
      return unless report.fetch("status") == "reproduced"

      error!("verification must be a JSON object") unless verification.is_a?(Hash)
      regression = verification["regression"]
      error!("VERIFY must record the regression spec run for the reproduced bug") unless regression
      require_exact_fields!(regression, %w[spec base candidate], "regression")
      spec = require_text!(regression["spec"], "regression spec")
      error!("regression spec must be a file path, not a command or filter: #{spec}") if spec.match?(/\s/)
      unless changed_paths.include?(spec)
        error!("regression spec #{spec} must be added or changed by the candidate")
      end
      { "base" => [report.fetch("base_sha"), "fail"], "candidate" => [candidate_sha, "pass"] }.each do |side, (sha, result)|
        run = regression[side]
        require_exact_fields!(run, %w[sha result excerpt], "regression #{side} run")
        error!("regression #{side} run must be on #{sha}") unless run["sha"] == sha
        allowed = strict ? [result] : %w[pass fail]
        error!("regression spec must #{result} on the #{side}") unless allowed.include?(run["result"])
        require_text!(run["excerpt"], "regression #{side} excerpt")
      end
    end

    private

    def error!(message)
      raise ReproError, message
    end

    def require_exact_fields!(value, fields, label)
      error!("#{label} must be a JSON object") unless value.is_a?(Hash)
      missing = fields - value.keys
      unknown = value.keys - fields
      error!("#{label} is missing field(s): #{missing.join(', ')}") if missing.any?
      error!("#{label} contains unknown field(s): #{unknown.join(', ')}") if unknown.any?
    end

    def require_nonempty_array!(value, label)
      error!("#{label} must be a non-empty array") unless value.is_a?(Array) && !value.empty?
      value
    end

    def require_text!(value, label)
      error!("#{label} must be non-empty text") unless value.is_a?(String) && !value.strip.empty?
      value
    end
  end
end
