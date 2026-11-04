# frozen_string_literal: true

require "prism"

module Sandi
  # The constants a script calls methods on as it runs. A method body runs when something calls it, so what is in
  # one belongs to its caller and not to the script that defines it.
  class Callees < Prism::Visitor
    # Where a script reads its arguments, parses them and touches files: not objects it builds.
    PLUMBING = %w[ARGV ENV OptionParser JSON File Dir Time].freeze

    def self.of(file)
      new.tap { |visitor| visitor.visit(Prism.parse_file(file).value) }.names
    end

    def initialize
      super
      @receivers = []
    end

    def names = @receivers.uniq - PLUMBING

    def visit_call_node(node)
      @receivers << node.receiver.slice if constant?(node.receiver)
      super
    end

    def visit_def_node(_node) = nil

    private

    def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
  end
end
