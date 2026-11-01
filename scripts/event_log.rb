#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "set"
require "time"

module PrGraph
  class ContractError < StandardError; end

  class EventLog
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze
    SESSION = /\A[A-Za-z0-9_-]{1,128}\z/.freeze
    GIT_SHA = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/i.freeze
    OUTCOME_NODE = {
      "verify" => "VERIFY",
      "ci" => "CI-WATCH",
      "bot" => "BOT-FEEDBACK",
      "self_review" => "SELF-REVIEW",
      "browser" => "REVIEW-APP",
      "scoring" => "VALIDATE"
    }.freeze
    WAKE_TRANSITIONS = {
      nil => ["registered"],
      "registered" => ["armed"],
      "armed" => %w[fired cancelled expired],
      "fired" => [],
      "cancelled" => [],
      "expired" => []
    }.freeze

    attr_reader :contract

    def initialize(contract_path: nil)
      contract_path ||= File.expand_path("../references/execution-contract-v1.json", __dir__)
      @contract = JSON.parse(File.read(contract_path))
      validate_contract!
    rescue JSON::ParserError => e
      raise ContractError, "invalid execution contract: #{e.message}"
    end

    def version
      contract.fetch("contract_version")
    end

    def read(path, allow_empty: false)
      return [] if allow_empty && !File.exist?(path)

      File.open(path, "rb") { |file| read_io(file, allow_empty: allow_empty) }
    end

    def validate_file!(path)
      events = read(path)
      validate_sequence!(events)
      events
    end

    def validate_event!(event)
      error!("event must be a JSON object") unless event.is_a?(Hash)

      envelope = contract.fetch("envelope")
      event_name = event["e"]
      event_contract = contract.fetch("events")[event_name]
      error!("unknown event type #{event_name.inspect}") unless event_contract

      required = envelope.fetch("required") + event_contract.fetch("required")
      missing = required.reject { |key| event.key?(key) }
      error!("missing required field(s): #{missing.join(', ')}") if missing.any?

      properties = envelope.fetch("properties")
        .merge(contract.fetch("common_properties"))
        .merge(event_contract.fetch("properties"))
      unknown = event.keys - properties.keys
      error!("unknown field(s) for #{event_name}: #{unknown.join(', ')}") if unknown.any?

      properties.each do |name, rules|
        validate_value!(name, event[name], rules) if event.key?(name)
      end

      if event_name == "edge"
        edge = [event["from"], event["to"]]
        error!("illegal graph edge #{edge.join(' -> ')}") unless legal_edges.include?(edge)
      end
      true
    end

    def validate_sequence!(events, allow_empty: false)
      return projection_for([], {}, {}) if allow_empty && events.empty?
      error!("event log is empty; recovery: start a new v#{version} run") if events.empty?

      attempts = {}
      wakes = {}
      run_id = nil
      session = nil
      published_sha = nil
      terminal = false

      events.each_with_index do |event, index|
        position = index + 1
        validate_event!(event)
        error!("event after terminal done at sequence #{position}") if terminal
        error!("sequence #{event['seq']} must be #{position}") unless event["seq"] == position

        run_id ||= event["run_id"]
        session ||= event["session"]
        error!("run_id changed at sequence #{position}") unless event["run_id"] == run_id
        error!("session changed at sequence #{position}") unless event["session"] == session

        if position == 1
          error!("first event must be run_start") unless event["e"] == "run_start"
        elsif event["e"] == "run_start"
          error!("run_start may appear only at sequence 1")
        end

        case event["e"]
        when "node"
          apply_node!(attempts, event)
        when "outcome"
          attempt = require_attempt!(attempts, event["attempt_id"], "outcome")
          expected = OUTCOME_NODE.fetch(event["kind"])
          error!("#{event['kind']} outcome belongs to #{expected}, not #{attempt['node']}") unless attempt["node"] == expected
        when "edge"
          attempt = require_attempt!(attempts, event["from_attempt_id"], "edge")
          error!("edge source #{event['from']} does not match attempt node #{attempt['node']}") unless attempt["node"] == event["from"]
        when "task"
          attempt = require_attempt!(attempts, event["attempt_id"], "task")
          error!("task node #{event['node']} does not match attempt node #{attempt['node']}") unless attempt["node"] == event["node"]
        when "wake"
          attempt = require_attempt!(attempts, event["attempt_id"], "wake")
          error!("wake node #{event['node']} does not match attempt node #{attempt['node']}") unless attempt["node"] == event["node"]
          apply_wake!(wakes, event)
        when "publish"
          published_sha = event["candidate_sha"]
        when "done"
          open_attempts = attempts.select { |_id, attempt| attempt["state"] == "open" }.keys
          open_wakes = wakes.select { |_id, wake| %w[registered armed].include?(wake["state"]) }.keys
          error!("done with open attempt(s): #{open_attempts.join(', ')}") if open_attempts.any?
          error!("done with live wake source(s): #{open_wakes.join(', ')}") if open_wakes.any?
          error!("done requires a prior publish event") unless published_sha
          error!("done candidate_sha does not match latest publish") unless event["candidate_sha"] == published_sha
          terminal = true
        end
      rescue ContractError => e
        raise ContractError, "sequence #{position}: #{e.message}"
      end

      projection_for(events, attempts, wakes).merge(
        "run_id" => run_id,
        "session" => session,
        "published_sha" => published_sha,
        "terminal" => terminal
      )
    end

    def emit(path, run_id:, session:, payload:, unique_by: nil)
      emit_many(path, run_id: run_id, session: session, payloads: [payload], unique_by: unique_by).first
    end

    def emit_many(path, run_id:, session:, payloads:, unique_by: nil)
      error!("payloads must be a non-empty array") unless payloads.is_a?(Array) && payloads.any?
      payloads.each { |payload| validate_payload_shape!(payload) }

      FileUtils.mkdir_p(File.dirname(path))
      lock_path = "#{path}.lock"
      File.open(lock_path, File::WRONLY | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        events = read(path, allow_empty: true)
        validate_sequence!(events, allow_empty: true)

        seen = Set.new
        events.each { |event| seen << event[unique_by] if unique_by && event[unique_by] }
        additions = []
        payloads.each do |payload|
          unique_value = unique_by && payload[unique_by]
          next if unique_value && seen.include?(unique_value)

          event = payload.merge(
            "v" => version,
            "run_id" => run_id,
            "seq" => events.length + additions.length + 1,
            "ts" => Time.now.utc.iso8601(6),
            "session" => session
          )
          additions << event
          seen << unique_value if unique_value
        end
        return [] if additions.empty?

        validate_sequence!(events + additions)
        append!(path, additions)
        additions
      end
    end

    private

    def append!(path, additions)
      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        additions.each { |event| file.puts(JSON.generate(event)) }
        file.flush
        file.fsync
      end
    end

    def nodes
      contract.fetch("graph").fetch("nodes")
    end

    def legal_edges
      @legal_edges ||= contract.fetch("graph").fetch("legal_edges").to_set
    end

    def error!(message)
      raise ContractError, message
    end

    def validate_contract!
      error!("contract_version must be 1") unless contract["contract_version"] == 1
      graph = contract.fetch("graph")
      error!("graph nodes must be unique") unless graph.fetch("nodes").uniq == graph.fetch("nodes")
      error!("dependency keys must exactly match graph nodes") unless graph.fetch("dependencies").keys.to_set == graph.fetch("nodes").to_set
      graph.fetch("dependencies").each do |node, dependencies|
        unknown = dependencies - graph.fetch("nodes")
        error!("#{node} has unknown dependencies: #{unknown.join(', ')}") if unknown.any?
      end
      graph.fetch("conditional_gates").each do |node, gates|
        error!("conditional gate target #{node} is unknown") unless graph.fetch("nodes").include?(node)
        gates.each do |gate|
          error!("conditional gate node #{gate['node']} is unknown") unless graph.fetch("nodes").include?(gate["node"])
          error!("conditional gate must name its condition") if gate["when"].to_s.empty?
        end
      end
      graph.fetch("legal_edges").each do |edge|
        error!("legal edge must contain two nodes") unless edge.is_a?(Array) && edge.length == 2
        unknown = edge - graph.fetch("nodes")
        error!("legal edge contains unknown nodes: #{unknown.join(', ')}") if unknown.any?
      end
    end

    def validate_payload_shape!(payload)
      error!("event payload must be a JSON object") unless payload.is_a?(Hash)
      reserved = contract.fetch("envelope").fetch("properties").keys - ["e"]
      collisions = payload.keys & reserved
      error!("payload may not set envelope field(s): #{collisions.join(', ')}") if collisions.any?
      error!("payload must include e") unless payload["e"]
    end

    def read_io(file, allow_empty: false)
      raw = file.read
      return [] if allow_empty && raw.empty?
      error!("event log is empty; recovery: start a new v#{version} run") if raw.empty?
      error!("torn final event; log was not modified") unless raw.end_with?("\n")

      raw.lines.each_with_index.map do |line, index|
        event = JSON.parse(line)
        unless event.key?("v")
          error!("unsupported legacy event at line #{index + 1}; preserve it read-only and start a new v#{version} UUID run")
        end
        event
      rescue JSON::ParserError => e
        error!("malformed JSON at line #{index + 1}: #{e.message}; log was not modified")
      end
    end

    def validate_value!(name, value, rules)
      allowed_types = Array(rules["type"])
      unless allowed_types.any? { |type| type_matches?(type, value) }
        error!("#{name} must have type #{allowed_types.join(' or ')}")
      end
      error!("#{name} must equal #{rules['const']}") if rules.key?("const") && value != rules["const"]
      error!("#{name} must be one of #{rules['enum'].join(', ')}") if rules["enum"] && !rules["enum"].include?(value)
      if rules["minimum"] && value.is_a?(Numeric) && value < rules["minimum"]
        error!("#{name} must be at least #{rules['minimum']}")
      end
      if rules["min_length"] && value.respond_to?(:length) && value.length < rules["min_length"]
        error!("#{name} must not be empty")
      end
      validate_format!(name, value, rules["format"]) if rules["format"]
    end

    def type_matches?(type, value)
      case type
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else error!("contract uses unknown type #{type}")
      end
    end

    def validate_format!(name, value, format)
      valid = case format
              when "uuid" then value.match?(UUID)
              when "session" then value.match?(SESSION)
              when "git_sha" then value.match?(GIT_SHA)
              when "node" then nodes.include?(value)
              when "node_or_orchestrator" then value == "ORCHESTRATOR" || nodes.include?(value)
              when "utc_timestamp"
                value.end_with?("Z") && Time.iso8601(value)
              else
                error!("contract uses unknown format #{format}")
              end
      error!("#{name} has invalid #{format} format") unless valid
    rescue ArgumentError
      error!("#{name} has invalid #{format} format")
    end

    def apply_node!(attempts, event)
      attempt_id = event["attempt_id"]
      attempt = attempts[attempt_id]
      if event["phase"] == "start"
        error!("attempt #{attempt_id} already exists") if attempt
        attempts[attempt_id] = {
          "node" => event["node"],
          "iteration" => event["iteration"],
          "state" => "open"
        }
        return
      end

      attempt = require_attempt!(attempts, attempt_id, "node #{event['phase']}")
      error!("attempt #{attempt_id} is already closed") unless attempt["state"] == "open"
      error!("attempt node changed from #{attempt['node']} to #{event['node']}") unless attempt["node"] == event["node"]
      error!("attempt iteration changed") unless attempt["iteration"] == event["iteration"]
      attempt["state"] = "closed" if event["phase"] == "done"
    end

    def require_attempt!(attempts, attempt_id, context)
      attempts[attempt_id] || error!("#{context} references unknown attempt #{attempt_id}")
    end

    def apply_wake!(wakes, event)
      wake_id = event["wake_id"]
      prior = wakes[wake_id]
      prior_state = prior && prior["state"]
      allowed = WAKE_TRANSITIONS.fetch(prior_state)
      error!("illegal wake transition #{prior_state || 'none'} -> #{event['state']}") unless allowed.include?(event["state"])
      if prior && (prior["node"] != event["node"] ||
                   prior["attempt_id"] != event["attempt_id"] ||
                   prior["kind"] != event["kind"])
        error!("wake source identity changed")
      end
      wakes[wake_id] = {
        "node" => event["node"],
        "attempt_id" => event["attempt_id"],
        "kind" => event["kind"],
        "state" => event["state"]
      }
    end

    def projection_for(events, attempts, wakes)
      {
        "contract_version" => version,
        "last_seq" => events.length,
        "active_attempts" => attempts.select { |_id, attempt| attempt["state"] == "open" }.keys.sort,
        "live_wakes" => wakes.select { |_id, wake| %w[registered armed].include?(wake["state"]) }.keys.sort
      }
    end
  end
end
