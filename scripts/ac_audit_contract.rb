#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "event_log"

module PrGraph
  # Validates the acceptance-criteria audit a green VERIFY carries.
  #
  # A fresh-context auditor reads the ticket and the candidate diff, never the plan or BUILD's own
  # report, and rules on every outcome clause. It also lists ticket criteria the outcome register
  # missed, so a thin register cannot hide a case the ticket asked for.
  class AcAuditContract
    class AuditError < ContractError; end

    ALLOWED_INPUTS = %w[triage_brief investigation_report].freeze
    CLAUSE_FIELDS = {
      "met" => %w[clause_id verdict evidence],
      "unmet" => %w[clause_id verdict reason],
      "unverifiable" => %w[clause_id verdict reason]
    }.freeze
    MISSED_FIELDS = {
      "met" => %w[criterion source verdict evidence],
      "unmet" => %w[criterion source verdict reason]
    }.freeze

    def validate!(verification, clause_ids:, candidate_sha:)
      audit = validate_shape!(verification, clause_ids: clause_ids, candidate_sha: candidate_sha)
      unmet = audit["clauses"].select { |item| item["verdict"] == "unmet" }.map { |item| item["clause_id"] }
      unmet += audit["missed"].select { |item| item["verdict"] == "unmet" }.map { |item| item["criterion"] }
      error!("ac_audit found unmet criteria: #{unmet.join('; ')}") if unmet.any?
      audit
    end

    # Everything except the pass rule, so a red VERIFY's audit can be saved and a malformed one is refused
    # while it can still be corrected.
    def validate_shape!(verification, clause_ids:, candidate_sha:)
      error!("verification must be a JSON object") unless verification.is_a?(Hash)
      audit = verification["ac_audit"]
      error!("VERIFY must record an ac_audit of the candidate against the ticket") unless audit
      require_exact_fields!(audit, %w[candidate_sha inputs clauses missed], "ac_audit")
      error!("ac_audit must audit the current candidate #{candidate_sha}") unless audit["candidate_sha"] == candidate_sha
      validate_inputs!(audit["inputs"])

      verdicts = require_array!(audit["clauses"], "ac_audit clauses").each_with_index.map do |item, index|
        validate_verdict!(item, CLAUSE_FIELDS, "ac_audit clause #{index + 1}")
        require_text!(item["clause_id"], "ac_audit clause #{index + 1} clause_id")
      end
      duplicates = verdicts.tally.select { |_, count| count > 1 }.keys
      error!("ac_audit rules on #{duplicates.join(', ')} more than once") if duplicates.any?
      unknown = verdicts - clause_ids
      error!("ac_audit references unknown outcome clause(s): #{unknown.join(', ')}") if unknown.any?
      missing = clause_ids - verdicts
      error!("ac_audit has no verdict for clause(s): #{missing.join(', ')}") if missing.any?

      require_array!(audit["missed"], "ac_audit missed").each_with_index do |item, index|
        label = "ac_audit missed criterion #{index + 1}"
        validate_verdict!(item, MISSED_FIELDS, label)
        require_text!(item["criterion"], "#{label} criterion")
        require_text!(item["source"], "#{label} source")
      end

      audit
    end

    private

    def validate_inputs!(inputs)
      require_array!(inputs, "ac_audit inputs")
      error!("ac_audit inputs must include triage_brief") unless inputs.include?("triage_brief")
      foreign = inputs - ALLOWED_INPUTS
      return if foreign.empty?

      error!("ac_audit must not read #{foreign.join(', ')}; it audits the ticket, not the plan or build")
    end

    def validate_verdict!(item, fields, label)
      error!("#{label} must be a JSON object") unless item.is_a?(Hash)
      verdict = item["verdict"]
      error!("#{label} verdict must be one of #{fields.keys.join(', ')}") unless fields.key?(verdict)
      require_exact_fields!(item, fields.fetch(verdict), label)
      if verdict == "met"
        evidence = require_array!(item["evidence"], "#{label} evidence")
        error!("#{label} evidence must be a non-empty array") if evidence.empty?
        evidence.each_with_index do |entry, index|
          require_exact_fields!(entry, %w[ref note], "#{label} evidence #{index + 1}")
          require_text!(entry["ref"], "#{label} evidence #{index + 1} ref")
          require_text!(entry["note"], "#{label} evidence #{index + 1} note")
        end
      else
        require_text!(item["reason"], "#{label} reason")
      end
    end

    def error!(message)
      raise AuditError, message
    end

    def require_exact_fields!(value, fields, label)
      error!("#{label} must be a JSON object") unless value.is_a?(Hash)
      missing = fields - value.keys
      unknown = value.keys - fields
      error!("#{label} is missing field(s): #{missing.join(', ')}") if missing.any?
      error!("#{label} contains unknown field(s): #{unknown.join(', ')}") if unknown.any?
    end

    def require_array!(value, label)
      error!("#{label} must be an array") unless value.is_a?(Array)
      value
    end

    def require_text!(value, label)
      error!("#{label} must be non-empty text") unless value.is_a?(String) && !value.strip.empty?
      value
    end
  end
end
