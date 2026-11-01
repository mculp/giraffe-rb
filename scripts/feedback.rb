#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "github_feedback"

def usage!
  warn <<~USAGE
    Usage:
      feedback.rb reconcile --repo OWNER/NAME --pr NUMBER --candidate-sha SHA --wake-id UUID --baseline-at TIME [--previous FILE] [--decisions FILE] [--timeout SECONDS]
      feedback.rb validate <file|->
  USAGE
  exit 1
end

def read_json(path)
  JSON.parse(path == "-" ? $stdin.read : File.read(path))
end

begin
  command = ARGV.shift || usage!
  if command == "validate"
    source = ARGV.shift || usage!
    usage! if ARGV.any?
    PrGraph::FeedbackContract.new.validate!(read_json(source))
    puts JSON.generate("valid" => true, "kind" => "feedback", "schema_version" => 1)
    exit 0
  end
  usage! unless command == "reconcile"

  options = {timeout: 30}
  parser = OptionParser.new do |values|
    values.on("--repo OWNER/NAME") { |value| options[:repo] = value }
    values.on("--pr NUMBER", Integer) { |value| options[:pr_number] = value }
    values.on("--candidate-sha SHA") { |value| options[:candidate_sha] = value }
    values.on("--wake-id UUID") { |value| options[:wake_id] = value }
    values.on("--baseline-at TIME") { |value| options[:baseline_at] = value }
    values.on("--previous FILE") { |value| options[:previous] = value }
    values.on("--decisions FILE") { |value| options[:decisions] = value }
    values.on("--timeout SECONDS", Integer) { |value| options[:timeout] = value }
  end
  parser.parse!(ARGV)
  required = %i[repo pr_number candidate_sha wake_id baseline_at]
  usage! if ARGV.any? || !options[:timeout].positive? || !required.all? { |key| options[key] }

  adapter = PrGraph::GitHubFeedback.new(
    runner: PrGraph::CommandRunner.new(timeout_seconds: options[:timeout])
  )
  result = adapter.reconcile(
    repo: options[:repo],
    pr_number: options[:pr_number],
    candidate_sha: options[:candidate_sha],
    wake_id: options[:wake_id],
    baseline_at: options[:baseline_at],
    previous: options[:previous] && read_json(options[:previous]),
    decisions: options[:decisions] && read_json(options[:decisions])
  )
  puts JSON.generate(result)
rescue PrGraph::ContractError, JSON::ParserError, OptionParser::ParseError, Errno::ENOENT => e
  warn "ERROR: #{e.message}"
  exit 1
end
