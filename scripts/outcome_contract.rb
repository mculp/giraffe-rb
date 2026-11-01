#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "event_log"

module PrGraph
  class OutcomeContract
    class OutcomeError < ContentError; end

    attr_reader :contract

    def initialize(contract_path: nil)
      contract_path ||= File.expand_path("../references/outcome-contract-v1.json", __dir__)
      @contract = JSON.parse(File.read(contract_path))
      validate_contract!
    rescue JSON::ParserError => e
      raise OutcomeError, "invalid outcome contract: #{e.message}"
    end

    def version
      contract.fetch("outcome_contract_version")
    end

    def validate_register!(triage)
      error!("triage brief must be a JSON object") unless triage.is_a?(Hash)
      register = triage["outcome_register"]
      error!("triage brief is missing outcome_register") unless register.is_a?(Hash)
      rules = contract.fetch("register")
      require_exact_fields!(register, rules.fetch("required_fields"), "outcome_register")
      require_text!(register["why"], "outcome_register.why")
      actors = require_nonempty_array!(register["actors"], "outcome_register.actors")
      positive = require_nonempty_array!(register["positive_postconditions"], "outcome_register.positive_postconditions")
      negative = require_nonempty_array!(register["negative_face"], "outcome_register.negative_face")
      gaps = require_array!(register["declared_gaps"], "outcome_register.declared_gaps")

      actors.each_with_index do |actor, index|
        require_exact_fields!(actor, rules.fetch("actor_fields"), "actor #{index + 1}")
        validate_id!(actor["id"], "actor #{index + 1} id")
        require_mechanism_free!(actor["situation"], "actor #{actor['id']} situation")
      end
      (positive + negative).each do |clause|
        require_exact_fields!(clause, rules.fetch("clause_fields"), "outcome clause")
        validate_id!(clause["id"], "outcome clause id")
        require_mechanism_free!(clause["statement"], "outcome clause #{clause['id']}")
      end
      gaps.each do |gap|
        require_exact_fields!(gap, rules.fetch("gap_fields"), "declared gap")
        validate_id!(gap["id"], "declared gap id")
        require_mechanism_free!(gap["reason"], "declared gap #{gap['id']}")
      end
      require_mechanism_free!(register["why"], "outcome_register.why")

      ids = actors.map { |actor| actor["id"] } + positive.map { |clause| clause["id"] } +
        negative.map { |clause| clause["id"] } + gaps.map { |gap| gap["id"] }
      duplicates = ids.group_by(&:itself).select { |_id, occurrences| occurrences.length > 1 }.keys
      error!("outcome register contains duplicate id(s): #{duplicates.join(', ')}") if duplicates.any?

      {
        "outcome_contract_version" => version,
        "actor_ids" => actors.map { |actor| actor.fetch("id") },
        "clause_ids" => (positive + negative).map { |clause| clause.fetch("id") },
        "declared_gap_ids" => gaps.map { |gap| gap.fetch("id") }
      }
    end

    def validate_plan!(triage, implementation_plan, test_plan)
      register_projection = validate_register!(triage)
      clauses = register_projection.fetch("clause_ids")
      validate_implementation_plan!(implementation_plan, clauses)
      coverage = validate_test_plan!(test_plan, clauses)
      register_projection.merge(coverage)
    end

    def read_artifact!(artifact, artifact_path:)
      unless artifact["content_type"] == "application/json"
        error!("#{artifact['family']} must use application/json content")
      end
      path = File.join(File.dirname(artifact_path), artifact.fetch("content_ref"))
      parsed = JSON.parse(File.binread(path))
      error!("#{artifact['family']} content must be a JSON object") unless parsed.is_a?(Hash)
      parsed
    rescue JSON::ParserError => e
      error!("#{artifact['family']} content is invalid JSON: #{e.message}")
    end

    private

    def error!(message)
      raise OutcomeError, message
    end

    def validate_contract!
      error!("outcome_contract_version must be 1") unless contract["outcome_contract_version"] == 1
      register = contract.fetch("register")
      @id_pattern = Regexp.new(register.fetch("id_pattern"))
      @mechanism_patterns = register.fetch("mechanism_patterns").map { |pattern| Regexp.new(pattern, Regexp::IGNORECASE) }
      %w[register implementation_plan test_plan].each do |section|
        error!("outcome contract is missing #{section}") unless contract[section].is_a?(Hash)
      end
    rescue KeyError, RegexpError => e
      error!("invalid outcome contract definition: #{e.message}")
    end

    def validate_implementation_plan!(plan, clause_ids)
      error!("implementation plan must be a JSON object") unless plan.is_a?(Hash)
      require_exact_fields!(plan, ["steps"], "implementation plan")
      steps = require_nonempty_array!(plan["steps"], "implementation plan steps")
      step_ids = []
      steps.each_with_index do |step, index|
        label = "implementation step #{index + 1}"
        rules = contract.fetch("implementation_plan")
        require_exact_fields!(step, rules.fetch("step_fields"), label)
        validate_id!(step["id"], "#{label} id")
        step_ids << step["id"]
        classification = step["classification"]
        unless rules.fetch("classifications").include?(classification)
          error!("#{label} classification must be CONFORM, EXTEND, or AMEND")
        end
        require_text!(step["intent"], "#{label} intent")
        outcome_ids = require_nonempty_array!(step["outcome_ids"], "#{label} outcome_ids")
        outcome_ids.each { |id| validate_known_clause!(id, clause_ids, "#{label} outcome") }
        evidence = require_nonempty_array!(step["evidence"], "#{label} evidence")
        validate_evidence!(evidence, label)
        actual_roles = evidence.reject { |item| item["kind"] == "gap" }.map { |item| item["role"] }
        missing_roles = rules.fetch("required_roles").fetch(classification) - actual_roles
        if missing_roles.any?
          error!("#{label} #{classification} is missing actual evidence role(s): #{missing_roles.join(', ')}")
        end
      end
      duplicates = step_ids.group_by(&:itself).select { |_id, occurrences| occurrences.length > 1 }.keys
      error!("implementation plan contains duplicate step id(s): #{duplicates.join(', ')}") if duplicates.any?
    end

    def validate_evidence!(evidence, label)
      rules = contract.fetch("implementation_plan")
      evidence.each_with_index do |item, index|
        item_label = "#{label} evidence #{index + 1}"
        error!("#{item_label} must be a JSON object") unless item.is_a?(Hash)
        if item["kind"] == "gap"
          require_exact_fields!(item, rules.fetch("gap_evidence_fields"), item_label)
          error!("#{item_label} role must be gap") unless item["role"] == "gap"
          require_text!(item["reason"], "#{item_label} reason")
          searched = require_nonempty_array!(item["searched"], "#{item_label} searched")
          searched.each { |source| require_text!(source, "#{item_label} searched source") }
        else
          require_exact_fields!(item, rules.fetch("actual_evidence_fields"), item_label)
          unless rules.fetch("actual_evidence_kinds").include?(item["kind"])
            error!("#{item_label} has unsupported evidence kind #{item['kind'].inspect}")
          end
          unless rules.fetch("roles").include?(item["role"]) && item["role"] != "gap"
            error!("#{item_label} has unsupported evidence role #{item['role'].inspect}")
          end
          require_text!(item["ref"], "#{item_label} ref")
          require_text!(item["claim"], "#{item_label} claim")
        end
      end
    end

    def validate_test_plan!(test_plan, clause_ids)
      error!("test plan must be a JSON object") unless test_plan.is_a?(Hash)
      require_exact_fields!(test_plan, ["coverage"], "test plan")
      coverage = require_nonempty_array!(test_plan["coverage"], "test plan coverage")
      rules = contract.fetch("test_plan")
      seen = []
      planned = []
      uncovered = []
      coverage.each_with_index do |item, index|
        label = "coverage item #{index + 1}"
        error!("#{label} must be a JSON object") unless item.is_a?(Hash)
        forbidden = item.keys & rules.fetch("forbidden_witness_fields")
        error!("#{label} contains concrete witness field(s): #{forbidden.join(', ')}") if forbidden.any?
        unknown = item.keys - rules.fetch("coverage_fields")
        error!("#{label} contains unknown field(s): #{unknown.join(', ')}") if unknown.any?
        require_text!(item["outcome_id"], "#{label} outcome_id")
        validate_known_clause!(item["outcome_id"], clause_ids, label)
        seen << item["outcome_id"]
        case item["status"]
        when "planned"
          require_exact_fields!(item, %w[outcome_id status planned_node strategy], label)
          unless rules.fetch("planned_nodes").include?(item["planned_node"])
            error!("#{label} has unsupported planned node #{item['planned_node'].inspect}")
          end
          require_mechanism_free!(item["strategy"], "#{label} strategy")
          planned << item["outcome_id"]
        when "uncovered"
          require_exact_fields!(item, %w[outcome_id status reason], label)
          require_text!(item["reason"], "#{label} reason")
          uncovered << item["outcome_id"]
        else
          error!("#{label} status must be planned or uncovered")
        end
      end
      duplicates = seen.group_by(&:itself).select { |_id, occurrences| occurrences.length > 1 }.keys
      error!("test plan contains duplicate outcome coverage: #{duplicates.join(', ')}") if duplicates.any?
      missing = clause_ids - seen
      error!("test plan leaves outcome clause(s) undeclared: #{missing.join(', ')}") if missing.any?
      {
        "planned_outcome_ids" => planned.sort,
        "uncovered_outcome_ids" => uncovered.sort
      }
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

    def require_nonempty_array!(value, label)
      value = require_array!(value, label)
      error!("#{label} must not be empty") if value.empty?
      value
    end

    def require_text!(value, label)
      error!("#{label} must be non-empty text") unless value.is_a?(String) && !value.strip.empty?
      value
    end

    def validate_id!(value, label)
      require_text!(value, label)
      error!("#{label} has invalid format") unless value.match?(@id_pattern)
    end

    def validate_known_clause!(value, clause_ids, label)
      validate_id!(value, label)
      error!("#{label} references unknown outcome clause #{value}") unless clause_ids.include?(value)
    end

    def require_mechanism_free!(value, label)
      require_text!(value, label)
      pattern = @mechanism_patterns.find { |candidate| value.match?(candidate) }
      error!("#{label} names an implementation mechanism: #{value[pattern]}") if pattern
    end
  end
end
