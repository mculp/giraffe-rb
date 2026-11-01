#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "artifact_log"
require_relative "coordinator_runtime"

def usage!
  warn <<~USAGE
    Usage:
      artifacts.rb put <session> <metadata-json|-> <content-file|->
      artifacts.rb replace <session> <stale-artifact-id> <metadata-json|-> <content-file|-> <reason>
      artifacts.rb link <session> <supersedes|invalidates> <from-id> <to-id> <reason>  # contract fixtures only
      artifacts.rb validate <artifacts.jsonl> <events.jsonl>
      artifacts.rb replay <artifacts.jsonl> <events.jsonl> [required-outcomes-json]
  USAGE
  exit 1
end

def state_root
  override = ENV["PR_GRAPH_STATE_ROOT"]
  return File.expand_path(override) unless override.to_s.empty?

  installed_root = File.expand_path("../.cursor-state-root", __dir__)
  return File.read(installed_root).chomp if File.file?(installed_root)

  product = File.expand_path(__FILE__).include?("/.cursor/") ? ".cursor" : ".claude"
  File.expand_path("~/#{product}/pr-graph")
end

def read_state(session)
  unless session.match?(PrGraph::EventLog::SESSION)
    raise PrGraph::ContractError, "missing or malformed conversation identity"
  end

  path = File.join(state_root, "active", session)
  raise PrGraph::ContractError, "no active run for conversation #{session}" unless File.file?(path)

  state = File.readlines(path, chomp: true).each_with_object({}) do |line, values|
    key, value = line.split("=", 2)
    values[key] = value if key && value
  end
  raise PrGraph::ContractError, "active state identity mismatch" unless state["session"] == session
  raise PrGraph::ContractError, "active state is missing events or run_id" unless state["events"] && state["run_id"]

  state
end

def artifact_path(execution_path)
  unless execution_path.end_with?(".jsonl")
    raise PrGraph::ContractError, "execution log path must end in .jsonl"
  end

  execution_path.sub(/\.jsonl\z/, ".artifacts.jsonl")
end

def json_input(source)
  JSON.parse(source == "-" ? $stdin.read : source)
end

begin
  command = ARGV.shift || usage!
  log = PrGraph::ArtifactLog.new

  case command
  when "put"
    session = ARGV.shift || usage!
    metadata_source = ARGV.shift || usage!
    content_source = ARGV.shift || usage!
    usage! if ARGV.any?
    raise PrGraph::ContractError, "metadata and content cannot both read from stdin" if metadata_source == "-" && content_source == "-"
    metadata = json_input(metadata_source)
    content = content_source == "-" ? $stdin.read : File.binread(content_source)
    state = read_state(session)
    coordinator = PrGraph::Coordinator.new(execution_path: state.fetch("events"), run_id: state.fetch("run_id"), session: session)
    puts JSON.generate(coordinator.put_artifact(metadata, content))
  when "replace"
    session = ARGV.shift || usage!
    stale = ARGV.shift || usage!
    metadata_source = ARGV.shift || usage!
    content_source = ARGV.shift || usage!
    reason = ARGV.shift || usage!
    usage! if ARGV.any?
    raise PrGraph::ContractError, "metadata and content cannot both read from stdin" if metadata_source == "-" && content_source == "-"
    metadata = json_input(metadata_source)
    content = content_source == "-" ? $stdin.read : File.binread(content_source)
    state = read_state(session)
    coordinator = PrGraph::Coordinator.new(execution_path: state.fetch("events"), run_id: state.fetch("run_id"), session: session)
    puts JSON.generate(coordinator.put_artifact(metadata, content, replaces: stale, reason: reason))
  when "link"
    session = ARGV.shift || usage!
    relation = ARGV.shift || usage!
    from_id = ARGV.shift || usage!
    to_id = ARGV.shift || usage!
    reason = ARGV.shift || usage!
    usage! if ARGV.any?
    unless ENV["PR_GRAPH_ALLOW_RAW_ARTIFACT_LINKS"] == "1"
      raise PrGraph::ContractError, "artifact lifecycle links are protected; use scripts/coordinate.rb"
    end
    state = read_state(session)
    event = log.emit(
      artifact_path(state.fetch("events")),
      execution_path: state.fetch("events"),
      run_id: state.fetch("run_id"),
      session: session,
      payload: {
        "e" => "link",
        "link_id" => SecureRandom.uuid,
        "relation" => relation,
        "from_artifact_id" => from_id,
        "to_artifact_id" => to_id,
        "reason" => reason
      }
    )
    puts JSON.generate(event)
  when "validate"
    artifacts = ARGV.shift || usage!
    execution = ARGV.shift || usage!
    usage! if ARGV.any?
    projection = log.validate_file!(artifacts, execution_path: execution)
    puts "valid pr-graph artifact v#{log.version} log: #{projection['last_seq']} event(s)"
  when "replay"
    artifacts = ARGV.shift || usage!
    execution = ARGV.shift || usage!
    outcomes_source = ARGV.shift
    usage! if ARGV.any?
    outcomes = outcomes_source ? JSON.parse(outcomes_source) : []
    artifact_events = log.read(artifacts, allow_empty: true)
    execution_events = PrGraph::EventLog.new.validate_file!(execution)
    projection = log.validate_sequence!(
      artifact_events,
      execution_events: execution_events,
      artifact_path: artifacts,
      required_outcomes: outcomes
    )
    puts JSON.pretty_generate(projection)
  else
    usage!
  end
rescue JSON::ParserError => e
  warn "ERROR: invalid artifact JSON: #{e.message}"
  exit 1
rescue PrGraph::ContractError, Errno::ENOENT, Errno::EACCES, Errno::EEXIST, Errno::ENOTDIR => e
  warn "ERROR: #{e.message}"
  exit 1
end
