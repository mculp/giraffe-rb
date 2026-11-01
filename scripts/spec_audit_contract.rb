#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "event_log"

module PrGraph
  # Validates the spec-value audit a green VERIFY carries.
  #
  # Every example in a spec file the candidate adds or changes is classified against the five ways a
  # spec fails to pin behavior, and its named behavior is mutated to prove the spec goes red. A spec
  # that restates the code it covers passes review and CI while catching nothing.
  class SpecAuditContract
    class SpecAuditError < ContractError; end

    CLASSES = %w[
      restates_literal
      framework_behavior
      mocks_subject
      duplicate_or_unplanned
      passes_without_change
    ].freeze
    MUTATION_RESULTS = %w[fail pass].freeze
    SPEC_PATH = %r{(\A|/)(spec|test)/.+(_spec\.rb|_test\.rb)\z|\.(spec|test)\.[jt]sx?\z}

    def self.spec_path?(path)
      SPEC_PATH.match?(path)
    end

    # Spec files the candidate adds or changes since the base.
    def self.changed_spec_paths(worktree, base_sha, candidate)
      return [] if base_sha == candidate

      _, _, status = Open3.capture3("git", "-C", worktree, "merge-base", "--is-ancestor", base_sha, candidate)
      raise SpecAuditError, "base #{base_sha} is not an ancestor of the candidate" unless status.success?

      stdout, stderr, status = Open3.capture3("git", "-C", worktree, "diff", "--name-only", "--diff-filter=AMR",
                                              base_sha, candidate)
      raise SpecAuditError, "git diff #{base_sha} #{candidate} failed: #{stderr.strip}" unless status.success?

      stdout.split("\n").select { |path| spec_path?(path) }
    end

    def validate!(verification, candidate_sha:, base_sha:, spec_paths:)
      audit = validate_shape!(verification, candidate_sha: candidate_sha, base_sha: base_sha, spec_paths: spec_paths)
      flagged = audit["specs"].filter_map do |spec|
        classes = spec["classes"]
        classes += ["passes_without_change"] if spec.dig("mutation", "result") == "pass"
        "#{spec['ref']} (#{classes.uniq.join(', ')})" if classes.any?
      end
      error!("spec_audit flagged spec(s) that do not pin behavior: #{flagged.join('; ')}") if flagged.any?
      audit
    end

    # Everything except the pass rule, so a red VERIFY's audit can be saved and a malformed one is refused
    # while it can still be corrected. base_sha and spec_paths are nil when the run cannot derive them yet.
    def validate_shape!(verification, candidate_sha:, base_sha: nil, spec_paths: nil)
      error!("verification must be a JSON object") unless verification.is_a?(Hash)
      audit = verification["spec_audit"]
      error!("VERIFY must record a spec_audit of the specs the candidate adds or changes") unless audit
      require_exact_fields!(audit, %w[candidate_sha base_sha specs], "spec_audit")
      error!("spec_audit must audit the current candidate #{candidate_sha}") unless audit["candidate_sha"] == candidate_sha
      require_sha!(audit["base_sha"], "spec_audit base_sha")
      if base_sha && audit["base_sha"] != base_sha
        error!("spec_audit must diff against the run's base #{base_sha}, not #{audit['base_sha']}")
      end

      refs = require_array!(audit["specs"], "spec_audit specs").each_with_index.map do |spec, index|
        validate_spec!(spec, "spec_audit spec #{index + 1}")
      end
      duplicates = refs.tally.select { |_, count| count > 1 }.keys
      error!("spec_audit lists #{duplicates.join(', ')} more than once") if duplicates.any?
      validate_coverage!(refs, spec_paths) if spec_paths
      audit
    end

    private

    def validate_spec!(spec, label)
      require_exact_fields!(spec, %w[ref behavior classes mutation], label)
      ref = require_text!(spec["ref"], "#{label} ref")
      error!("#{label} ref must be path:line, got #{ref}") unless ref.match?(/\A\S+:\d+\z/)
      require_text!(spec["behavior"], "#{label} behavior")
      classes = require_array!(spec["classes"], "#{label} classes")
      unknown = classes - CLASSES
      error!("#{label} has unknown class(es) #{unknown.join(', ')}; use #{CLASSES.join(', ')}") if unknown.any?
      error!("#{label} repeats a class") if classes.uniq.size != classes.size

      mutation = spec["mutation"]
      require_exact_fields!(mutation, %w[change result], "#{label} mutation")
      require_text!(mutation["change"], "#{label} mutation change")
      return ref if MUTATION_RESULTS.include?(mutation["result"])

      error!("#{label} mutation result must be one of #{MUTATION_RESULTS.join(', ')}")
    end

    def validate_coverage!(refs, spec_paths)
      audited = refs.map { |ref| ref.sub(/:\d+\z/, "") }
      foreign = audited.uniq - spec_paths
      error!("spec_audit cites spec(s) the candidate did not add or change: #{foreign.join(', ')}") if foreign.any?
      missing = spec_paths - audited
      error!("spec_audit has no entry for changed spec file(s): #{missing.join(', ')}") if missing.any?
    end

    def error!(message)
      raise SpecAuditError, message
    end

    def require_exact_fields!(value, fields, label)
      error!("#{label} must be a JSON object") unless value.is_a?(Hash)
      missing = fields - value.keys
      unknown = value.keys - fields
      error!("#{label} is missing field(s): #{missing.join(', ')}") if missing.any?
      error!("#{label} contains unknown field(s): #{unknown.join(', ')}") if unknown.any?
    end

    def require_array!(value, label)
      error!("#{label} must be an array") unless value.is_a?(Array)
      value
    end

    def require_text!(value, label)
      error!("#{label} must be non-empty text") unless value.is_a?(String) && !value.strip.empty?
      value
    end

    def require_sha!(value, label)
      error!("#{label} must be a full 40-character Git SHA") unless value.is_a?(String) && value.match?(/\A\h{40}\z/)
      value
    end
  end
end
