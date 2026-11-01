#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "seed_runtime"

def usage!
  warn <<~USAGE
    Usage:
      seed.rb prepare --plan FILE --script FILE --manifest FILE
      seed.rb execute --plan FILE --script FILE --manifest FILE --approved-sha SHA -- RUNNER [ARG ...]
      seed.rb validate plan|manifest FILE
      seed.rb key --run-id UUID --scenario ID --label LABEL

    The execute command appends the approved runner script as one final argument to RUNNER.
    For a review app, RUNNER is normally: bin/ops review-app runner --pr NUMBER
  USAGE
  exit 1
end

begin
  command = ARGV.shift || usage!
  contract = PrGraph::SeedContract.new

  if command == "validate"
    kind = ARGV.shift || usage!
    source = ARGV.shift || usage!
    usage! if ARGV.any?
    content = JSON.parse(File.binread(source))
    kind == "plan" ? contract.validate_plan!(content) : kind == "manifest" ? contract.validate_manifest!(content) : usage!
    puts JSON.generate("valid" => true, "kind" => kind, "schema_version" => 1)
    exit 0
  end

  if command == "key"
    options = {}
    OptionParser.new do |parser|
      parser.on("--run-id UUID") { |value| options[:run_id] = value }
      parser.on("--scenario ID") { |value| options[:scenario] = value }
      parser.on("--label LABEL") { |value| options[:label] = value }
    end.parse!(ARGV)
    usage! if ARGV.any? || %i[run_id scenario label].any? { |key| options[key].nil? }
    puts contract.stable_key(options[:run_id], options[:scenario], options[:label])
    exit 0
  end

  options = {}
  parser = OptionParser.new do |values|
    values.on("--plan FILE") { |value| options[:plan_path] = value }
    values.on("--script FILE") { |value| options[:script_path] = value }
    values.on("--manifest FILE") { |value| options[:manifest_path] = value }
    values.on("--approved-sha SHA") { |value| options[:approved_sha] = value }
  end
  parser.order!(ARGV)
  required = %i[plan_path script_path manifest_path]
  usage! unless required.all? { |key| options[key] }

  plan = JSON.parse(File.binread(options.fetch(:plan_path)))
  runtime = PrGraph::SeedRuntime.new(contract: contract)
  result = case command
           when "prepare"
             usage! if ARGV.any?
             runtime.prepare(
               plan: plan,
               script_path: options.fetch(:script_path),
               manifest_path: options.fetch(:manifest_path)
             )
           when "execute"
             ARGV.shift if ARGV.first == "--"
             runtime.execute(
               plan: plan,
               script_path: options.fetch(:script_path),
               manifest_path: options.fetch(:manifest_path),
               approved_sha: options[:approved_sha],
               command: ARGV
             )
           else
             usage!
           end
  runtime.captured_stdout.each_line do |line|
    $stderr.write(line) unless line.start_with?(PrGraph::SeedRuntime::RESULT_MARKER)
  end
  $stderr.write(runtime.captured_stderr)
  puts JSON.generate(result)
  exit 1 if %w[failed uncertain].include?(result.fetch("status"))
rescue PrGraph::ContractError, JSON::ParserError, OptionParser::ParseError, Errno::ENOENT => e
  warn "ERROR: #{e.message}"
  exit 1
end
