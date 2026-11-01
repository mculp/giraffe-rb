#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "event_log"
require_relative "failure_log"

def usage!
  warn "Usage: failures.rb validate|replay <failures.jsonl> <events.jsonl>"
  exit 1
end

begin
  command = ARGV.shift || usage!
  failures = ARGV.shift || usage!
  execution = ARGV.shift || usage!
  usage! if ARGV.any?
  execution_events = PrGraph::EventLog.new.validate_file!(execution)
  projection = PrGraph::FailureLog.new.validate_file!(failures, execution_events: execution_events)
  case command
  when "validate"
    puts "valid pr-graph failure v#{projection['failure_contract_version']} log: #{projection['last_seq']} event(s)"
  when "replay"
    puts JSON.pretty_generate(projection)
  else
    usage!
  end
rescue PrGraph::ContractError, Errno::ENOENT, Errno::EACCES => e
  warn "ERROR: #{e.message}"
  exit 1
end
