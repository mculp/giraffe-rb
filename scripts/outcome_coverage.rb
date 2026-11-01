#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "event_log"

module PrGraph
  class OutcomeCoverage
    class CoverageError < ContractError; end

    attr_reader :contract

    def initialize(contract_path: nil)
      contract_path ||= File.expand_path("../references/outcome-coverage-v1.json", __dir__)
      @contract = JSON.parse(File.read(contract_path))
      validate_contract!
    rescue JSON::ParserError => e
      raise CoverageError, "invalid outcome coverage contract: #{e.message}"
    end

    def version
      contract.fetch("outcome_coverage_version")
    end

    def build_impact!(node:, attempt_id:, outputs:, clauses:, prior:, polarity:)
      error!("outcome impact polarity must be advanced or contradicted") unless %w[advanced contradicted].include?(polarity)
      known = clauses.to_h { |outcome_id| [outcome_id, true] }
      evidence = Hash.new { |hash, key| hash[key] = [] }
      outputs.each do |artifact|
        artifact.fetch("covered_outcomes").each do |outcome_id|
          error!("#{node} evidence names undeclared outcome clause #{outcome_id}") unless known[outcome_id]
          evidence[outcome_id] << evidence_reference(artifact)
        end
      end
      if %w[TRIAGE PLAN DONE].include?(node) && evidence.any?
        error!("#{node} must not introduce concrete outcome evidence")
      end
      impact = {
        "outcome_coverage_version" => version,
        "node" => node,
        "attempt_id" => attempt_id,
        "clauses" => clauses.map do |outcome_id|
          refs = evidence[outcome_id].sort_by { |item| item.fetch("artifact_id") }
          state = prior.dig("clauses", outcome_id, "state")
          status = if refs.any?
                     polarity
                   elsif state && state != "uncovered"
                     "unchanged"
                   else
                     "uncovered"
                   end
          {"outcome_id" => outcome_id, "status" => status, "evidence" => refs}
        end
      }
      validate_impact!(impact, clauses: clauses, artifacts: outputs)
      impact
    end

    def project!(clauses:, attempts:, manifests:, artifacts:, planned_uncovered: [])
      artifacts_by_id = artifacts.to_h { |artifact| [artifact.fetch("artifact_id"), artifact] }
      supports = Hash.new { |hash, key| hash[key] = [] }
      contradictions = Hash.new { |hash, key| hash[key] = [] }
      history = []

      manifests.each do |attempt_id, manifest|
        result = manifest["result"]
        next unless result

        attempt = attempts.fetch(attempt_id)
        impact = result["outcome_impact"]
        error!("attempt result #{attempt_id} is missing outcome impact") unless impact

        unless impact["node"] == attempt["node"] && impact["attempt_id"] == attempt_id
          error!("outcome impact identity mismatch for #{attempt_id}")
        end

        validate_impact!(impact, clauses: clauses, artifacts: artifacts)
        history << {
          "attempt_id" => attempt_id,
          "node" => attempt.fetch("node"),
          "result_state" => result.fetch("state"),
          "clauses" => impact.fetch("clauses")
        }
        next unless attempt["state"] == "closed"

        impact.fetch("clauses").each do |item|
          target = case item.fetch("status")
                   when "advanced" then supports
                   when "contradicted" then contradictions
                   end
          next unless target

          item.fetch("evidence").each do |reference|
            artifact = artifacts_by_id.fetch(reference.fetch("artifact_id"))
            next unless artifact.fetch("status") == "current"

            target[item.fetch("outcome_id")] << reference.merge(
              "node" => artifact.fetch("node"),
              "attempt_id" => artifact.fetch("attempt_id")
            )
          end
        end
      end

      clause_projection = clauses.to_h do |outcome_id|
        positive = unique_evidence(supports[outcome_id])
        negative = unique_evidence(contradictions[outcome_id])
        state = if positive.any? && negative.any?
                  "conflicting"
                elsif positive.any?
                  "covered"
                elsif negative.any?
                  "contradicted"
                else
                  "uncovered"
                end
        [outcome_id, {"state" => state, "supports" => positive, "contradictions" => negative}]
      end
      projection = {
        "outcome_coverage_version" => version,
        "clauses" => clause_projection,
        "conflicts" => clause_projection.select { |_id, value| value["state"] == "conflicting" }.keys,
        "uncovered" => clause_projection.select { |_id, value| value["state"] == "uncovered" }.keys,
        "history" => history
      }
      validate_terminal_results!(
        manifests,
        attempts: attempts,
        clauses: clauses,
        projection: projection,
        planned_uncovered: planned_uncovered
      )
      projection
    end

    def finalize!(requested, clauses:, projection:, planned_uncovered:)
      error!("DONE requires an outcome disposition JSON object") unless requested.is_a?(Hash)
      require_exact_fields!(requested, ["clauses"], "terminal disposition")
      requested_items = requested["clauses"]
      error!("terminal disposition clauses must be an array") unless requested_items.is_a?(Array)

      seen = []
      items = requested_items.map.with_index do |item, index|
        label = "terminal disposition item #{index + 1}"
        error!("#{label} must be a JSON object") unless item.is_a?(Hash)
        outcome_id = item["outcome_id"]
        error!("#{label} names unknown outcome clause #{outcome_id.inspect}") unless clauses.include?(outcome_id)
        seen << outcome_id
        status = item["status"]
        unless contract.fetch("terminal_statuses").include?(status)
          error!("#{label} has unsupported status #{status.inspect}")
        end
        current = projection.fetch("clauses").fetch(outcome_id)
        if status == "covered"
          require_exact_fields!(item, %w[outcome_id status], label)
          error!("#{outcome_id} cannot be covered while current evidence is #{current.fetch('state')}") unless current.fetch("state") == "covered"
          {
            "outcome_id" => outcome_id,
            "status" => status,
            "reason" => nil,
            "evidence" => current.fetch("supports")
          }
        else
          require_exact_fields!(item, %w[outcome_id status reason], label)
          require_text!(item["reason"], "#{label} reason")
          if status == "deliberately_excluded" && !planned_uncovered.include?(outcome_id)
            error!("#{outcome_id} was not deliberately excluded by PLAN")
          end
          {
            "outcome_id" => outcome_id,
            "status" => status,
            "reason" => item.fetch("reason"),
            "evidence" => unique_evidence(current.fetch("supports") + current.fetch("contradictions"))
          }
        end
      end
      duplicates = seen.group_by(&:itself).select { |_id, values| values.length > 1 }.keys
      error!("terminal disposition contains duplicate outcome clause(s): #{duplicates.join(', ')}") if duplicates.any?
      missing = clauses - seen
      error!("terminal disposition leaves outcome clause(s) undeclared: #{missing.join(', ')}") if missing.any?
      {
        "outcome_coverage_version" => version,
        "clauses" => items
      }
    end

    def validate_impact!(impact, clauses:, artifacts:)
      require_exact_fields!(impact, %w[outcome_coverage_version node attempt_id clauses], "outcome impact")
      error!("outcome impact version must be #{version}") unless impact["outcome_coverage_version"] == version
      error!("outcome impact node is invalid") unless impact["node"].is_a?(String) && !impact["node"].empty?
      error!("outcome impact attempt is invalid") unless impact["attempt_id"].is_a?(String) && impact["attempt_id"].match?(EventLog::UUID)
      items = impact["clauses"]
      error!("outcome impact clauses must be an array") unless items.is_a?(Array)
      artifacts_by_id = artifacts.to_h { |artifact| [artifact.fetch("artifact_id"), artifact] }
      seen = []
      items.each_with_index do |item, index|
        label = "outcome impact item #{index + 1}"
        require_exact_fields!(item, %w[outcome_id status evidence], label)
        outcome_id = item["outcome_id"]
        error!("#{label} names unknown outcome clause #{outcome_id.inspect}") unless clauses.include?(outcome_id)
        seen << outcome_id
        status = item["status"]
        error!("#{label} has unsupported status #{status.inspect}") unless contract.fetch("impact_statuses").include?(status)
        evidence = item["evidence"]
        error!("#{label} evidence must be an array") unless evidence.is_a?(Array)
        if %w[advanced contradicted].include?(status)
          error!("#{label} requires actual evidence") if evidence.empty?
        elsif evidence.any?
          error!("#{label} #{status} must not imply evidence")
        end
        evidence.each do |reference|
          require_exact_fields!(reference, %w[artifact_id perspective], "#{label} evidence")
          artifact = artifacts_by_id[reference["artifact_id"]]
          error!("#{label} references unknown evidence artifact #{reference['artifact_id']}") unless artifact
          unless artifact["node"] == impact["node"] && artifact["attempt_id"] == impact["attempt_id"]
            error!("#{label} evidence belongs to another node attempt")
          end
          error!("#{label} evidence perspective mismatch") unless artifact["perspective"] == reference["perspective"]
          unless artifact.fetch("covered_outcomes").include?(outcome_id)
            error!("#{label} evidence does not name #{outcome_id}")
          end
        end
        evidence_ids = evidence.map { |reference| reference["artifact_id"] }
        unless evidence_ids.uniq == evidence_ids
          error!("#{label} contains duplicate evidence artifact(s)")
        end
      end
      duplicates = seen.group_by(&:itself).select { |_id, values| values.length > 1 }.keys
      error!("outcome impact contains duplicate clause(s): #{duplicates.join(', ')}") if duplicates.any?
      missing = clauses - seen
      error!("outcome impact leaves clause(s) undeclared: #{missing.join(', ')}") if missing.any?
      true
    end

    private

    def error!(message)
      raise CoverageError, message
    end

    def validate_contract!
      error!("outcome_coverage_version must be 1") unless contract["outcome_coverage_version"] == 1
      error!("impact statuses are invalid") unless contract["impact_statuses"] == %w[advanced contradicted unchanged uncovered]
      expected = %w[covered deliberately_excluded inexpressible explicitly_unexamined]
      error!("terminal statuses are invalid") unless contract["terminal_statuses"] == expected
    end

    def evidence_reference(artifact)
      {
        "artifact_id" => artifact.fetch("artifact_id"),
        "perspective" => artifact.fetch("perspective")
      }
    end

    def unique_evidence(evidence)
      evidence.uniq { |item| item.fetch("artifact_id") }.sort_by { |item| item.fetch("artifact_id") }
    end

    def validate_terminal_results!(manifests, attempts:, clauses:, projection:, planned_uncovered:)
      manifests.each do |attempt_id, manifest|
        result = manifest["result"]
        next unless result && result["node"] == "DONE"

        disposition = result["outcome_disposition"]
        error!("DONE result #{attempt_id} is missing terminal outcome disposition") unless disposition

        requested = {
          "clauses" => disposition.fetch("clauses").map do |item|
            value = {"outcome_id" => item.fetch("outcome_id"), "status" => item.fetch("status")}
            value["reason"] = item["reason"] if item["status"] != "covered"
            value
          end
        }
        expected = finalize!(
          requested,
          clauses: clauses,
          projection: projection,
          planned_uncovered: planned_uncovered
        )
        error!("terminal outcome disposition no longer matches current evidence") unless disposition == expected
      end
    end

    def require_exact_fields!(value, fields, label)
      error!("#{label} must be a JSON object") unless value.is_a?(Hash)
      missing = fields - value.keys
      unknown = value.keys - fields
      error!("#{label} is missing field(s): #{missing.join(', ')}") if missing.any?
      error!("#{label} contains unknown field(s): #{unknown.join(', ')}") if unknown.any?
    end

    def require_text!(value, label)
      error!("#{label} must be non-empty text") unless value.is_a?(String) && !value.strip.empty?
    end
  end
end
