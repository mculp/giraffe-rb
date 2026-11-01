#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "artifact_log"

module PrGraph
  class LineageContract
    class LineageError < ContractError; end

    attr_reader :contract

    def initialize(contract_path: nil, artifact_log: ArtifactLog.new)
      contract_path ||= File.expand_path("../references/lineage-contract-v1.json", __dir__)
      @artifact_log = artifact_log
      @contract = JSON.parse(File.read(contract_path))
      validate_contract!
    rescue JSON::ParserError => e
      raise LineageError, "invalid lineage contract: #{e.message}"
    end

    def version
      contract.fetch("lineage_contract_version")
    end

    def candidate_dependent?(family)
      contract.fetch("families").fetch(family).fetch("candidate_dependent")
    rescue KeyError
      error!("unknown lineage family #{family}")
    end

    def validate_artifact!(artifact)
      family = artifact.fetch("family")
      return true unless candidate_dependent?(family)

      candidate = artifact["candidate_sha"]
      unless candidate.is_a?(String) && candidate.match?(EventLog::GIT_SHA)
        error!("candidate-dependent artifact #{family} requires a full candidate SHA")
      end
      if family != source_family && artifact["input_sha"] != candidate
        error!("candidate-dependent artifact #{family} must consume its candidate SHA")
      end
      true
    end

    def trigger_node
      contract.dig("invalidation", "trigger_node")
    end

    def source_family
      contract.dig("invalidation", "source_family")
    end

    private

    def error!(message)
      raise LineageError, message
    end

    def validate_contract!
      error!("lineage_contract_version must be 1") unless contract["lineage_contract_version"] == 1
      unless contract["execution_contract_version"] == @artifact_log.contract.fetch("execution_contract_version")
        error!("lineage execution contract version mismatch")
      end
      unless contract["artifact_contract_version"] == @artifact_log.version
        error!("lineage artifact contract version mismatch")
      end
      artifact_families = @artifact_log.contract.fetch("families").keys.sort
      lineage_families = contract.fetch("families").keys.sort
      error!("lineage families do not match artifact contract") unless lineage_families == artifact_families
      contract.fetch("families").each do |family, rules|
        unless rules.keys == ["candidate_dependent"] && [true, false].include?(rules["candidate_dependent"])
          error!("invalid candidate policy for #{family}")
        end
      end
      error!("lineage source family is unknown") unless lineage_families.include?(source_family)
      source_nodes = @artifact_log.contract.dig("families", source_family, "nodes")
      error!("lineage source family does not belong to trigger node") unless source_nodes.include?(trigger_node)
    rescue KeyError => e
      error!("invalid lineage contract definition: #{e.message}")
    end
  end
end
