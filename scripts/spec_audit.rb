#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "spec_audit_contract"

def usage!
  warn <<~USAGE
    Usage:
      spec_audit.rb paths <worktree> <base-sha> <candidate-sha>
      spec_audit.rb check <worktree> <base-sha> <candidate-sha> <spec-audit.json>
  USAGE
  exit 1
end

begin
  command = ARGV.shift || usage!
  usage! unless %w[paths check].include?(command)
  worktree, base, candidate, audit_path = ARGV
  usage! unless worktree && base && candidate && ARGV.size == (command == "check" ? 4 : 3)
  paths = PrGraph::SpecAuditContract.changed_spec_paths(worktree, base, candidate)
  if command == "paths"
    puts JSON.generate(paths)
  else
    audit = PrGraph::SpecAuditContract.new.validate!(
      {"spec_audit" => JSON.parse(File.read(audit_path))}, candidate_sha: candidate, base_sha: base, spec_paths: paths
    )
    puts JSON.generate("specs" => audit["specs"].size, "spec_files" => paths.size)
  end
rescue JSON::ParserError => e
  warn "ERROR: invalid spec_audit JSON: #{e.message}"
  exit 1
rescue PrGraph::ContractError, Errno::ENOENT, Errno::EACCES => e
  warn "ERROR: #{e.message}"
  exit 1
end
