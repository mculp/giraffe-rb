#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "set"
require "time"
require_relative "event_log"

module PrGraph
  class FailureLog
    class FailureError < ContractError; end

    ID = /\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,127}\z/.freeze
    REVISION = /\A[^\r\n]{1,128}\z/.freeze

    attr_reader :contract

    def initialize(contract_path: nil, execution_log: EventLog.new)
      contract_path ||= File.expand_path("../references/failure-contract-v1.json", __dir__)
      @contract = JSON.parse(File.read(contract_path))
      @execution_log = execution_log
      validate_contract!
    rescue JSON::ParserError => e
      raise FailureError, "invalid failure contract: #{e.message}"
    end

    def version
      contract.fetch("failure_contract_version")
    end

    def max_consecutive_cycles
      contract.fetch("max_consecutive_cycles")
    end

    def read(path, allow_empty: false)
      return [] if allow_empty && !File.exist?(path)

      File.open(path, "rb") { |file| read_io(file, allow_empty: allow_empty) }
    end

    def validate_file!(path, execution_events:)
      validate_sequence!(read(path, allow_empty: true), execution_events: execution_events)
    end

    def validate_sequence!(events, execution_events:)
      context = execution_context(execution_events)
      findings = []
      occurrences = {}
      dedupe_keys = Set.new
      stops = []
      stop_ids = Set.new

      events.each_with_index do |event, index|
        position = index + 1
        validate_event!(event)
        error!("sequence #{event['seq']} must be #{position}") unless event["seq"] == position
        error!("run_id changed at sequence #{position}") unless event["run_id"] == context.fetch("run_id")
        error!("session changed at sequence #{position}") unless event["session"] == context.fetch("session")
        if event["e"] == "finding"
          apply_finding!(event, context, findings, occurrences, dedupe_keys)
        else
          apply_stop!(event, occurrences, stops, stop_ids)
        end
      rescue ContractError => e
        raise FailureError, "failure sequence #{position}: #{e.message}"
      end

      {
        "failure_contract_version" => version,
        "last_seq" => events.length,
        "findings" => findings,
        "stops" => stops,
        "stopped" => stops.any?
      }
    end

    def record(path, execution_path:, run_id:, session:, finding:, stop_history: nil)
      validate_finding_payload!(finding)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open("#{path}.lock", File::WRONLY | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        events = read(path, allow_empty: true)
        execution_events = @execution_log.validate_file!(execution_path)
        projection = validate_sequence!(events, execution_events: execution_events)
        duplicate = projection.fetch("findings").find do |existing|
          dedupe_key(existing) == dedupe_key(finding)
        end
        if duplicate
          expected = finding.reject { |key, _value| key == "occurrence_id" }
          actual = duplicate.reject do |key, _value|
            %w[v run_id seq ts session e occurrence_id].include?(key)
          end
          error!("duplicate failure revision conflicts with persisted finding") unless actual == expected
          stop = stop_for(projection, duplicate)
          if stop_history && !stop
            payload = stop_payload(duplicate, stop_history)
            stop = envelope_payloads(events, [payload], run_id, session).first
            validate_sequence!(events + [stop], execution_events: execution_events)
            append_events!(path, [stop])
          end
          return {"finding" => duplicate, "deduplicated" => true, "stop" => stop}
        end

        finding = finding.merge("e" => "finding", "occurrence_id" => SecureRandom.uuid)
        payloads = [finding]
        payloads << stop_payload(finding, stop_history) if stop_history
        additions = envelope_payloads(events, payloads, run_id, session)
        validate_sequence!(events + additions, execution_events: execution_events)
        append_events!(path, additions)
        {"finding" => additions.first, "deduplicated" => false, "stop" => additions[1]}
      end
    end

    def validate_identity!(failure_id, revision)
      error!("missing or malformed failure identity") unless failure_id.is_a?(String) && failure_id.match?(ID)
      error!("missing or malformed failure revision") unless revision.is_a?(String) && revision.match?(REVISION)
      true
    end

    def build_batch(pending:, candidate_sha:, batch_id: SecureRandom.uuid)
      error!("BUILD cannot claim an empty failure queue") unless pending.is_a?(Array) && pending.any?
      error!("failure batch id is invalid") unless batch_id.is_a?(String) && batch_id.match?(EventLog::UUID)
      unless candidate_sha.is_a?(String) && candidate_sha.match?(EventLog::GIT_SHA)
        error!("failure batch candidate is invalid")
      end
      unless pending.all? { |finding| finding["candidate_sha"] == candidate_sha }
        error!("failure queue contains a non-current candidate")
      end
      groups = pending.group_by { |finding| finding.fetch("failure_id") }.sort.map do |failure_id, findings|
        validate_identity!(failure_id, findings.first.fetch("revision"))
        occurrence_ids = findings.map { |finding| finding.fetch("occurrence_id") }.sort
        unless occurrence_ids.uniq == occurrence_ids && occurrence_ids.all? { |id| id.is_a?(String) && id.match?(EventLog::UUID) }
          error!("failure batch occurrence identities are invalid")
        end
        {"failure_id" => failure_id, "occurrence_ids" => occurrence_ids}
      end
      {"batch_id" => batch_id, "candidate_sha" => candidate_sha, "failures" => groups}
    end

    def consecutive_batches(processed_batches:, failure_id:)
      validate_identity!(failure_id, "history")
      history = []
      processed_batches.sort_by { |batch| batch.fetch("done_seq") }.reverse_each do |batch|
        identities = batch.fetch("failures").map { |failure| failure.fetch("failure_id") }
        break unless identities.include?(failure_id)

        history << batch
      end
      history.reverse
    end

    def stop_history(processed_batches:, failure_id:)
      history = consecutive_batches(processed_batches: processed_batches, failure_id: failure_id)
      return nil if history.length < max_consecutive_cycles

      {"batch_ids" => history.map { |batch| batch.fetch("batch_id") }}
    end

    private

    def error!(message)
      raise FailureError, message
    end

    def validate_contract!
      error!("failure_contract_version must be 1") unless contract["failure_contract_version"] == 1
      error!("failure execution version mismatch") unless contract["execution_contract_version"] == @execution_log.version
      error!("max_consecutive_cycles must be positive") unless contract["max_consecutive_cycles"].is_a?(Integer) && contract["max_consecutive_cycles"].positive?
      error!("failure contract must define finding and stop") unless contract.dig("events")&.keys&.sort == %w[finding stop]
    end

    def read_io(file, allow_empty: false)
      raw = file.read
      return [] if allow_empty && raw.empty?
      error!("failure log is empty") if raw.empty?
      error!("torn final failure event; log was not modified") unless raw.end_with?("\n")
      raw.lines.each_with_index.map do |line, index|
        event = JSON.parse(line)
        error!("unsupported legacy failure event at line #{index + 1}") unless event.key?("v")
        event
      rescue JSON::ParserError => e
        error!("malformed failure JSON at line #{index + 1}: #{e.message}; log was not modified")
      end
    end

    def execution_context(events)
      error!("execution log is empty") if events.empty?
      attempts = {}
      events.each do |event|
        next unless event["e"] == "node" && event["phase"] == "start"

        attempts[event["attempt_id"]] = event["node"]
      end
      {
        "run_id" => events.first.fetch("run_id"),
        "session" => events.first.fetch("session"),
        "nodes" => @execution_log.contract.dig("graph", "nodes"),
        "attempts" => attempts
      }
    end

    def validate_event!(event)
      error!("failure event must be a JSON object") unless event.is_a?(Hash)
      event_contract = contract.dig("events", event["e"])
      error!("unknown failure event type #{event['e'].inspect}") unless event_contract
      required = contract.dig("envelope", "required") + event_contract.fetch("required")
      missing = required - event.keys
      error!("missing required field(s): #{missing.join(', ')}") if missing.any?
      allowed = required
      unknown = event.keys - allowed
      error!("unknown field(s) for #{event['e']}: #{unknown.join(', ')}") if unknown.any?
      error!("v must equal #{version}") unless event["v"] == version
      error!("run_id has invalid UUID format") unless event["run_id"].is_a?(String) && event["run_id"].match?(EventLog::UUID)
      error!("session has invalid format") unless event["session"].is_a?(String) && event["session"].match?(EventLog::SESSION)
      error!("seq must be positive") unless event["seq"].is_a?(Integer) && event["seq"].positive?
      error!("ts has invalid UTC timestamp format") unless event["ts"].is_a?(String)
      Time.iso8601(event["ts"])
      error!("ts must be UTC") unless event["ts"].end_with?("Z")
    rescue ArgumentError
      error!("ts has invalid UTC timestamp format")
    end

    def validate_finding_payload!(finding)
      error!("failure finding must be a JSON object") unless finding.is_a?(Hash)
      required = contract.dig("events", "finding", "required") - ["occurrence_id"]
      missing = required - finding.keys
      unknown = finding.keys - required - ["occurrence_id"]
      error!("missing required finding field(s): #{missing.join(', ')}") if missing.any?
      error!("unknown finding field(s): #{unknown.join(', ')}") if unknown.any?
      validate_identity!(finding["failure_id"], finding["revision"])
    end

    def apply_finding!(event, context, findings, occurrences, dedupe_keys)
      validate_identity!(event["failure_id"], event["revision"])
      unless event["occurrence_id"].is_a?(String) && event["occurrence_id"].match?(EventLog::UUID)
        error!("occurrence_id has invalid UUID format")
      end
      error!("duplicate occurrence_id #{event['occurrence_id']}") if occurrences.key?(event["occurrence_id"])
      error!("unknown failure source node") unless context.fetch("nodes").include?(event["source_node"])
      source_node = context.fetch("attempts")[event["source_attempt_id"]]
      error!("failure references unknown source attempt") unless source_node
      error!("failure source node does not match its attempt") unless source_node == event["source_node"]
      error!("failure candidate has invalid Git SHA") unless event["candidate_sha"].is_a?(String) && event["candidate_sha"].match?(EventLog::GIT_SHA)
      error!("failure reason must not be empty") unless event["reason"].is_a?(String) && !event["reason"].strip.empty?
      artifact_ids = event["artifact_ids"]
      unless artifact_ids.is_a?(Array) && artifact_ids.any? && artifact_ids.uniq == artifact_ids && artifact_ids.all? { |id| id.is_a?(String) && id.match?(EventLog::UUID) }
        error!("failure artifact_ids must contain unique artifact UUIDs")
      end
      error!("duplicate failure source revision") unless dedupe_keys.add?(dedupe_key(event))
      occurrences[event["occurrence_id"]] = event
      findings << event
    end

    def apply_stop!(event, occurrences, stops, stop_ids)
      unless event["stop_id"].is_a?(String) && event["stop_id"].match?(EventLog::UUID)
        error!("stop_id has invalid UUID format")
      end
      error!("duplicate stop_id #{event['stop_id']}") unless stop_ids.add?(event["stop_id"])
      finding = occurrences[event["triggering_occurrence_id"]]
      error!("stop references unknown triggering occurrence") unless finding
      error!("stop failure identity does not match occurrence") unless event["failure_id"] == finding["failure_id"]
      unless event["processed_cycles"].is_a?(Integer) && event["processed_cycles"] >= max_consecutive_cycles
        error!("stop processed_cycles is below the recurrence cap")
      end
      batch_ids = event["batch_ids"]
      unless batch_ids.is_a?(Array) && batch_ids.length == event["processed_cycles"] && batch_ids.uniq == batch_ids && batch_ids.all? { |id| id.is_a?(String) && id.match?(EventLog::UUID) }
        error!("stop batch_ids do not prove processed cycles")
      end
      error!("stop reason must not be empty") unless event["reason"].is_a?(String) && !event["reason"].strip.empty?
      stops << event
    end

    def dedupe_key(finding)
      %w[failure_id source_node candidate_sha revision].map { |field| finding[field] }
    end

    def stop_for(projection, finding)
      projection.fetch("stops").find { |stop| stop["triggering_occurrence_id"] == finding["occurrence_id"] }
    end

    def stop_payload(finding, stop_history)
      {
        "e" => "stop",
        "stop_id" => SecureRandom.uuid,
        "failure_id" => finding.fetch("failure_id"),
        "triggering_occurrence_id" => finding.fetch("occurrence_id"),
        "processed_cycles" => stop_history.fetch("batch_ids").length,
        "batch_ids" => stop_history.fetch("batch_ids"),
        "reason" => "failure recurred after #{max_consecutive_cycles} consecutive BUILD cycles"
      }
    end

    def envelope_payloads(existing, payloads, run_id, session)
      payloads.each_with_index.map do |payload, index|
        payload.merge(
          "v" => version,
          "run_id" => run_id,
          "seq" => existing.length + index + 1,
          "ts" => Time.now.utc.iso8601(6),
          "session" => session
        )
      end
    end

    def append_events!(path, events)
      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        events.each { |event| file.puts(JSON.generate(event)) }
        file.flush
        file.fsync
      end
    end
  end
end
