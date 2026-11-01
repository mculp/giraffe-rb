#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "github_pr_ci"

def usage!
  warn <<~USAGE
    Usage:
      pr_ci.rb publish --repo OWNER/NAME --worktree PATH --base REF --head REF --title TEXT --body-file PATH [--pr NUMBER] [--timeout SECONDS]
      pr_ci.rb reconcile-ci --repo OWNER/NAME --pr NUMBER --candidate-sha SHA --wake-id UUID [--timeout SECONDS]
      pr_ci.rb validate publish|ci <file|->
  USAGE
  exit 1
end

begin
  command = ARGV.shift || usage!
  if command == "validate"
    kind = ARGV.shift || usage!
    source = ARGV.shift || usage!
    usage! if ARGV.any?
    content = JSON.parse(source == "-" ? $stdin.read : File.read(source))
    contract = PrGraph::PrCiContract.new
    kind == "publish" ? contract.validate_publish!(content) : kind == "ci" ? contract.validate_ci!(content) : usage!
    puts JSON.generate("valid" => true, "kind" => kind, "schema_version" => 1)
    exit 0
  end

  options = {timeout: 30}
  parser = OptionParser.new do |values|
    values.on("--repo OWNER/NAME") { |value| options[:repo] = value }
    values.on("--worktree PATH") { |value| options[:worktree] = value }
    values.on("--base REF") { |value| options[:base] = value }
    values.on("--head REF") { |value| options[:head] = value }
    values.on("--title TEXT") { |value| options[:title] = value }
    values.on("--body-file PATH") { |value| options[:body_file] = value }
    values.on("--pr NUMBER", Integer) { |value| options[:pr_number] = value }
    values.on("--candidate-sha SHA") { |value| options[:candidate_sha] = value }
    values.on("--wake-id UUID") { |value| options[:wake_id] = value }
    values.on("--timeout SECONDS", Integer) { |value| options[:timeout] = value }
  end
  parser.parse!(ARGV)
  usage! if ARGV.any? || !options[:timeout].positive?
  adapter = PrGraph::GitHubPrCi.new(runner: PrGraph::CommandRunner.new(timeout_seconds: options[:timeout]))

  result = case command
           when "publish"
             required = %i[repo worktree base head title body_file]
             usage! unless required.all? { |key| options[key] }
             adapter.publish(
               repo: options[:repo],
               worktree: options[:worktree],
               base: options[:base],
               head: options[:head],
               title: options[:title],
               body_file: options[:body_file],
               pr_number: options[:pr_number]
             )
           when "reconcile-ci"
             required = %i[repo pr_number candidate_sha wake_id]
             usage! unless required.all? { |key| options[key] }
             adapter.reconcile_ci(
               repo: options[:repo],
               pr_number: options[:pr_number],
               candidate_sha: options[:candidate_sha],
               wake_id: options[:wake_id]
             )
           else
             usage!
           end
  puts JSON.generate(result)
rescue PrGraph::ContractError, JSON::ParserError, OptionParser::ParseError, Errno::ENOENT => e
  warn "ERROR: #{e.message}"
  exit 1
end
