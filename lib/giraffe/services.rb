# frozen_string_literal: true

require_relative "../../scripts/outcome_contract"
require_relative "../../scripts/ac_audit_contract"
require_relative "../../scripts/spec_audit_contract"

module Giraffe
  # What a harness lends its steps. A StepContext is made for one attempt, but this lives as long as the harness.
  class Services
    attr_reader :git, :checks, :github, :model

    def initialize(git:, checks:, github:, model:)
      @git, @checks, @github, @model = git, checks, github, model
    end

    # Each reads its reference file when made, so each waits until a step wants it, and is then kept.
    def outcome_contract = @outcome_contract ||= PrGraph::OutcomeContract.new
    def ac_audit_contract = @ac_audit_contract ||= PrGraph::AcAuditContract.new
    def spec_audit_contract = @spec_audit_contract ||= PrGraph::SpecAuditContract.new
  end
end
