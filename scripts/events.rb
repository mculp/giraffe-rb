#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "event_log"

PROTECTED_LIFECYCLE_EVENTS = %w[node outcome edge wake publish done].freeze

def usage!
  warn "Usage: events.rb emit <session> <json|-> | validate <events.jsonl> | replay <events.jsonl>"
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

begin
  command = ARGV.shift || usage!
  log = PrGraph::EventLog.new

  case command
  when "emit"
    session = ARGV.shift || usage!
    source = ARGV.shift || usage!
    usage! if ARGV.any?
    payload = JSON.parse(source == "-" ? $stdin.read : source)
    if PROTECTED_LIFECYCLE_EVENTS.include?(payload["e"]) && ENV["PR_GRAPH_ALLOW_RAW_EVENTS"] != "1"
      raise PrGraph::ContractError,
            "#{payload['e']} is a protected lifecycle event; use scripts/coordinate.rb"
    end
    state = read_state(session)
    event = log.emit(
      state.fetch("events"),
      run_id: state.fetch("run_id"),
      session: session,
      payload: payload
    )
    puts JSON.generate(event)
  when "validate"
    path = ARGV.shift || usage!
    usage! if ARGV.any?
    events = log.validate_file!(path)
    puts "valid pr-graph v#{log.version} log: #{events.length} event(s)"
  when "replay"
    path = ARGV.shift || usage!
    usage! if ARGV.any?
    events = log.validate_file!(path)
    puts JSON.pretty_generate(log.validate_sequence!(events))
  else
    usage!
  end
rescue JSON::ParserError => e
  warn "ERROR: invalid event JSON: #{e.message}"
  exit 1
rescue PrGraph::ContractError, Errno::ENOENT, Errno::EACCES => e
  warn "ERROR: #{e.message}"
  exit 1
end
