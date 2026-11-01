#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "set"
require "time"
require_relative "event_log"

module PrGraph
  class ArtifactLog
    SHA256 = /\A[0-9a-f]{64}\z/i.freeze
    OUTCOME_ID = /\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,127}\z/.freeze

    attr_reader :contract

    def initialize(contract_path: nil, execution_log: EventLog.new)
      contract_path ||= File.expand_path("../references/artifact-contract-v1.json", __dir__)
      @contract = JSON.parse(File.read(contract_path))
      @execution_log = execution_log
      validate_contract!
    rescue JSON::ParserError => e
      raise ContractError, "invalid artifact contract: #{e.message}"
    end

    def version
      contract.fetch("artifact_contract_version")
    end

    def read(path, allow_empty: false)
      return [] if allow_empty && !File.exist?(path)

      File.open(path, "rb") { |file| read_io(file, allow_empty: allow_empty) }
    end

    def validate_file!(path, execution_path:)
      events = read(path, allow_empty: true)
      execution_events = @execution_log.validate_file!(execution_path)
      validate_sequence!(events, execution_events: execution_events, artifact_path: path)
    end

    def validate_event!(event)
      error!("artifact event must be a JSON object") unless event.is_a?(Hash)

      envelope = contract.fetch("envelope")
      event_name = event["e"]
      event_contract = contract.fetch("events")[event_name]
      error!("unknown artifact event type #{event_name.inspect}") unless event_contract

      required = envelope.fetch("required") + event_contract.fetch("required")
      missing = required.reject { |key| event.key?(key) }
      error!("missing required field(s): #{missing.join(', ')}") if missing.any?

      properties = envelope.fetch("properties").merge(event_contract.fetch("properties"))
      unknown = event.keys - properties.keys
      error!("unknown field(s) for #{event_name}: #{unknown.join(', ')}") if unknown.any?

      properties.each do |name, rules|
        validate_value!(name, event[name], rules) if event.key?(name)
      end
      true
    end

    def validate_sequence!(events, execution_events:, artifact_path:, required_outcomes: [])
      execution = execution_context(execution_events)
      artifacts = {}
      statuses = {}
      links = []
      link_ids = Set.new

      events.each_with_index do |event, index|
        position = index + 1
        validate_event!(event)
        error!("sequence #{event['seq']} must be #{position}") unless event["seq"] == position
        error!("run_id changed at sequence #{position}") unless event["run_id"] == execution.fetch("run_id")
        error!("session changed at sequence #{position}") unless event["session"] == execution.fetch("session")

        case event["e"]
        when "artifact"
          apply_artifact!(artifacts, statuses, event, execution, artifact_path)
        when "link"
          error!("link_id #{event['link_id']} already exists") unless link_ids.add?(event["link_id"])
          apply_link!(artifacts, statuses, event)
          links << event
        end
      rescue ContractError => e
        raise ContractError, "artifact sequence #{position}: #{e.message}"
      end

      projection_for(events, artifacts, statuses, links, required_outcomes)
    end

    def store(path, execution_path:, run_id:, session:, metadata:, content:)
      error!("artifact metadata must be a JSON object") unless metadata.is_a?(Hash)
      generated = %w[e artifact_id content_ref content_sha256 content_bytes v run_id seq ts session]
      collisions = metadata.keys & generated
      error!("artifact metadata may not set generated field(s): #{collisions.join(', ')}") if collisions.any?

      artifact_id = SecureRandom.uuid
      content = content.to_s.b
      content_ref = "#{artifact_directory_name(path)}/#{artifact_id}.blob"
      blob_path = File.join(File.dirname(path), content_ref)
      blob_written = false
      FileUtils.mkdir_p(File.dirname(blob_path), mode: 0o700)
      File.open(blob_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      blob_written = true

      payload = metadata.merge(
        "e" => "artifact",
        "artifact_id" => artifact_id,
        "content_ref" => content_ref,
        "content_sha256" => Digest::SHA256.hexdigest(content),
        "content_bytes" => content.bytesize
      )
      emit(path, execution_path: execution_path, run_id: run_id, session: session, payload: payload)
    rescue StandardError
      cleanup_unreferenced_blob(blob_path, content) if blob_written
      raise
    end

    # Runs the checks store and emit_many run, without writing a blob or an event, so a caller can
    # validate content before a save that cannot be undone.
    def check(path, execution_path:, run_id:, session:, metadata:, content:)
      error!("artifact metadata must be a JSON object") unless metadata.is_a?(Hash)
      generated = %w[e artifact_id content_ref content_sha256 content_bytes v run_id seq ts session]
      collisions = metadata.keys & generated
      error!("artifact metadata may not set generated field(s): #{collisions.join(', ')}") if collisions.any?

      artifact_id = SecureRandom.uuid
      content = content.to_s.b
      payload = metadata.merge(
        "e" => "artifact",
        "artifact_id" => artifact_id,
        "content_ref" => "#{artifact_directory_name(path)}/#{artifact_id}.blob",
        "content_sha256" => Digest::SHA256.hexdigest(content),
        "content_bytes" => content.bytesize
      )
      validate_payload_shape!(payload)
      events = read(path, allow_empty: true)
      execution_events = @execution_log.validate_file!(execution_path)
      validate_live_payloads!([payload], execution_events)
      validate_sequence!(events, execution_events: execution_events, artifact_path: path)
      addition = payload.merge("v" => version, "run_id" => run_id, "seq" => events.length + 1,
                               "ts" => Time.now.utc.iso8601(6), "session" => session)
      validate_event!(addition)
      validate_artifact_rules!(addition, execution_context(execution_events))
      true
    end

    def emit(path, execution_path:, run_id:, session:, payload:)
      emit_many(
        path,
        execution_path: execution_path,
        run_id: run_id,
        session: session,
        payloads: [payload]
      ).first
    end

    def emit_many(path, execution_path:, run_id:, session:, payloads:)
      error!("artifact payloads must be a non-empty array") unless payloads.is_a?(Array) && payloads.any?
      payloads.each { |payload| validate_payload_shape!(payload) }
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      lock_path = "#{path}.lock"
      File.open(lock_path, File::WRONLY | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        events = read(path, allow_empty: true)
        execution_events = @execution_log.validate_file!(execution_path)
        validate_sequence!(events, execution_events: execution_events, artifact_path: path)
        validate_live_payloads!(payloads, execution_events)

        additions = payloads.each_with_index.map do |payload, index|
          payload.merge(
            "v" => version,
            "run_id" => run_id,
            "seq" => events.length + index + 1,
            "ts" => Time.now.utc.iso8601(6),
            "session" => session
          )
        end
        validate_sequence!(events + additions, execution_events: execution_events, artifact_path: path)
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

    def error!(message)
      raise ContractError, message
    end

    def families
      contract.fetch("families")
    end

    def execution_nodes
      @execution_log.contract.fetch("graph").fetch("nodes")
    end

    def validate_contract!
      error!("artifact_contract_version must be 1") unless contract["artifact_contract_version"] == 1
      unless contract["execution_contract_version"] == @execution_log.version
        error!("artifact contract requires execution contract v#{contract['execution_contract_version']}")
      end
      error!("artifact families must not be empty") if families.empty?
      families.each do |name, rules|
        error!("artifact family #{name} must name at least one node") unless rules["nodes"].is_a?(Array) && rules["nodes"].any?
        unknown = rules["nodes"] - execution_nodes
        error!("artifact family #{name} has unknown nodes: #{unknown.join(', ')}") if unknown.any?
        error!("artifact family #{name} must declare quality") unless [true, false].include?(rules["quality"])
        error!("artifact family #{name} must declare wake_required") unless [true, false].include?(rules["wake_required"])
      end
    end

    def validate_payload_shape!(payload)
      error!("artifact payload must be a JSON object") unless payload.is_a?(Hash)
      reserved = contract.fetch("envelope").fetch("properties").keys - ["e"]
      collisions = payload.keys & reserved
      error!("artifact payload may not set envelope field(s): #{collisions.join(', ')}") if collisions.any?
      error!("artifact payload must include e") unless payload["e"]
    end

    def validate_live_payloads!(payloads, execution_events)
      attempt_states = {}
      execution_events.each do |event|
        next unless event["e"] == "node"

        if event["phase"] == "start"
          attempt_states[event["attempt_id"]] = "open"
        elsif event["phase"] == "done"
          attempt_states[event["attempt_id"]] = "closed"
        end
      end
      payloads.each do |payload|
        next unless payload["e"] == "artifact"
        next unless attempt_states[payload["attempt_id"]] == "closed"

        error!("artifact attempt #{payload['attempt_id']} is already closed")
      end
    end

    def read_io(file, allow_empty: false)
      raw = file.read
      return [] if allow_empty && raw.empty?
      error!("artifact log is empty") if raw.empty?
      error!("torn final artifact event; log was not modified") unless raw.end_with?("\n")

      raw.lines.each_with_index.map do |line, index|
        event = JSON.parse(line)
        unless event.key?("v")
          error!("unsupported legacy artifact event at line #{index + 1}; preserve it read-only")
        end
        event
      rescue JSON::ParserError => e
        error!("malformed artifact JSON at line #{index + 1}: #{e.message}; log was not modified")
      end
    end

    def execution_context(events)
      error!("execution log is empty") if events.empty?
      attempts = {}
      wakes = {}
      events.each do |event|
        if event["e"] == "node" && event["phase"] == "start"
          attempts[event["attempt_id"]] = {"node" => event["node"]}
        elsif event["e"] == "wake"
          wakes[event["wake_id"]] = {
            "node" => event["node"],
            "attempt_id" => event["attempt_id"],
            "state" => event["state"]
          }
        end
      end
      {
        "run_id" => events.first.fetch("run_id"),
        "session" => events.first.fetch("session"),
        "attempts" => attempts,
        "wakes" => wakes
      }
    end

    def apply_artifact!(artifacts, statuses, event, execution, artifact_path)
      artifact_id = event["artifact_id"]
      error!("artifact_id #{artifact_id} already exists") if artifacts.key?(artifact_id)
      validate_artifact_rules!(event, execution)
      verify_content!(event, artifact_path)
      artifacts[artifact_id] = event
      statuses[artifact_id] = "current"
    end

    # The attempt, family, lineage, and wake rules for one artifact event; the blob is checked separately.
    def validate_artifact_rules!(event, execution)
      artifact_id = event["artifact_id"]
      attempt = execution.fetch("attempts")[event["attempt_id"]]
      error!("artifact references unknown attempt #{event['attempt_id']}") unless attempt
      error!("artifact node #{event['node']} does not match attempt node #{attempt['node']}") unless event["node"] == attempt["node"]

      family = families.fetch(event["family"])
      unless family.fetch("nodes").include?(event["node"])
        error!("artifact family #{event['family']} does not belong to #{event['node']}")
      end
      if family.fetch("quality")
        error!("quality artifact #{artifact_id} requires candidate_sha") unless event["candidate_sha"]
        error!("quality artifact #{artifact_id} requires at least one covered outcome") if event["covered_outcomes"].empty?
        unless event["candidate_sha"] == event["input_sha"]
          error!("quality artifact #{artifact_id} candidate_sha must match input_sha")
        end
      end
      if event["covered_outcomes"].uniq != event["covered_outcomes"]
        error!("artifact #{artifact_id} contains duplicate covered outcomes")
      end
      if family.fetch("wake_required") && !event["wake_id"]
        error!("artifact family #{event['family']} requires a wake source")
      end
      if event["wake_id"]
        wake = execution.fetch("wakes")[event["wake_id"]]
        error!("artifact references unknown wake source #{event['wake_id']}") unless wake
        unless wake["attempt_id"] == event["attempt_id"] && wake["node"] == event["node"]
          error!("artifact wake source does not belong to its attempt")
        end
        error!("artifact wake source has not fired") unless wake["state"] == "fired"
      end
    end

    def apply_link!(artifacts, statuses, event)
      from_id = event["from_artifact_id"]
      to_id = event["to_artifact_id"]
      error!("artifact link cannot target itself") if from_id == to_id
      source = artifacts[from_id]
      target = artifacts[to_id]
      error!("link source #{from_id} does not exist") unless source
      error!("link target #{to_id} does not exist") unless target
      error!("link source #{from_id} is not current") unless statuses[from_id] == "current"
      error!("link target #{to_id} is already #{statuses[to_id]}") unless statuses[to_id] == "current"
      if event["relation"] == "supersedes"
        unless source["family"] == target["family"] && source["node"] == target["node"]
          error!("supersession requires matching artifact family and node")
        end
        statuses[to_id] = "superseded"
      else
        statuses[to_id] = "invalidated"
      end
    end

    def verify_content!(event, artifact_path)
      expected_ref = "#{artifact_directory_name(artifact_path)}/#{event['artifact_id']}.blob"
      error!("content_ref must be #{expected_ref}") unless event["content_ref"] == expected_ref
      path = File.join(File.dirname(artifact_path), event["content_ref"])
      error!("artifact content is missing: #{event['content_ref']}") unless File.file?(path)
      error!("artifact content size does not match #{event['artifact_id']}") unless File.size(path) == event["content_bytes"]
      actual = Digest::SHA256.file(path).hexdigest
      error!("artifact checksum does not match #{event['artifact_id']}") unless actual == event["content_sha256"]
    end

    def projection_for(events, artifacts, statuses, links, required_outcomes)
      error!("required outcomes must be an array") unless required_outcomes.is_a?(Array)
      error!("required outcomes must contain only strings") unless required_outcomes.all? { |outcome| outcome.is_a?(String) }
      required = required_outcomes.uniq.sort
      required.each { |outcome| validate_format!("required_outcome", outcome, "outcome_id") }
      evidence = Hash.new { |hash, key| hash[key] = [] }
      artifacts.each do |artifact_id, artifact|
        next unless statuses[artifact_id] == "current"
        next unless families.fetch(artifact["family"]).fetch("quality")

        artifact["covered_outcomes"].each { |outcome| evidence[outcome] << artifact_id }
      end
      covered = required.select { |outcome| evidence.key?(outcome) }
      {
        "artifact_contract_version" => version,
        "last_seq" => events.length,
        "artifacts" => artifacts.values.map do |artifact|
          {
            "artifact_id" => artifact["artifact_id"],
            "family" => artifact["family"],
            "node" => artifact["node"],
            "attempt_id" => artifact["attempt_id"],
            "candidate_sha" => artifact["candidate_sha"],
            "status" => statuses.fetch(artifact["artifact_id"]),
            "covered_outcomes" => artifact["covered_outcomes"]
          }
        end,
        "links" => links.map { |link| link.slice("link_id", "relation", "from_artifact_id", "to_artifact_id", "reason") },
        "coverage" => {
          "required" => required,
          "covered" => covered,
          "uncovered" => required - covered,
          "evidence" => evidence.sort.to_h
        }
      }
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
      if value.is_a?(Array) && rules["items"]
        value.each { |item| validate_value!("#{name} item", item, rules["items"]) }
      end
      validate_format!(name, value, rules["format"]) if rules["format"] && !value.nil?
    end

    def type_matches?(type, value)
      case type
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "boolean" then value == true || value == false
      when "array" then value.is_a?(Array)
      when "null" then value.nil?
      else error!("artifact contract uses unknown type #{type}")
      end
    end

    def validate_format!(name, value, format)
      valid = case format
              when "uuid" then value.match?(EventLog::UUID)
              when "session" then value.match?(EventLog::SESSION)
              when "git_sha" then value.match?(EventLog::GIT_SHA)
              when "sha256" then value.match?(SHA256)
              when "node" then execution_nodes.include?(value)
              when "artifact_family" then families.key?(value)
              when "artifact_ref" then value.match?(%r{\A[A-Za-z0-9_.-]+\.artifacts/[0-9a-f-]{36}\.blob\z}i)
              when "outcome_id" then value.match?(OUTCOME_ID)
              when "utc_timestamp" then value.end_with?("Z") && Time.iso8601(value)
              else error!("artifact contract uses unknown format #{format}")
              end
      error!("#{name} has invalid #{format} format") unless valid
    rescue ArgumentError
      error!("#{name} has invalid #{format} format")
    end

    def artifact_directory_name(path)
      basename = File.basename(path)
      unless basename.end_with?(".artifacts.jsonl")
        error!("artifact log path must end in .artifacts.jsonl")
      end

      "#{basename.delete_suffix('.artifacts.jsonl')}.artifacts"
    end

    def cleanup_unreferenced_blob(path, content)
      return unless File.file?(path)
      return unless Digest::SHA256.file(path).hexdigest == Digest::SHA256.hexdigest(content)

      File.unlink(path)
    rescue SystemCallError
      nil
    end
  end
end
