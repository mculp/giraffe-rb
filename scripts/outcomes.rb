#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "outcome_contract"

def usage!
  warn <<~USAGE
    Usage:
      outcomes.rb register <triage-brief.json>
      outcomes.rb plan <triage-brief.json> <implementation-plan.json> <test-plan.json>
  USAGE
  exit 1
end

def read_json(path)
  JSON.parse(File.read(path))
end

begin
  command = ARGV.shift || usage!
  validator = PrGraph::OutcomeContract.new
  projection = case command
               when "register"
                 path = ARGV.shift || usage!
                 usage! if ARGV.any?
                 validator.validate_register!(read_json(path))
               when "plan"
                 triage = ARGV.shift || usage!
                 implementation = ARGV.shift || usage!
                 tests = ARGV.shift || usage!
                 usage! if ARGV.any?
                 validator.validate_plan!(read_json(triage), read_json(implementation), read_json(tests))
               else
                 usage!
               end
  puts JSON.pretty_generate(projection)
rescue JSON::ParserError => e
  warn "ERROR: invalid outcome JSON: #{e.message}"
  exit 1
rescue PrGraph::ContractError, Errno::ENOENT, Errno::EACCES => e
  warn "ERROR: #{e.message}"
  exit 1
end
