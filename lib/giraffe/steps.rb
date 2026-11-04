# frozen_string_literal: true

module Giraffe
  # Where the harness finds who does a node's work. A node's step is the class in this namespace named for it, so
  # BUILD is Steps::Build and CI-WATCH is Steps::CiWatch, and a file in steps/ is all it takes to add one.
  #
  # A step is built with no arguments and called with the StepContext of the attempt it is to do: call(context).
  # What it returns is not read. By the time it returns, the attempt must be over, through context.finish or the
  # coordinator's fail. Otherwise it raises: context.ask_a_person parks it until a person answers, and any other
  # error pauses the run.
  #
  # A module here is not a step but a mixin into Harness, which does a node that has no step as its own step_<node>
  # method. A mixin can share its node's name, as Steps::Build does, so turning a node into a step means replacing
  # its module with the class, and Harness stops including it.
  module Steps
    def self.for(node)
      name = node.split("-").map(&:capitalize).join
      step = const_get(name, false) if const_defined?(name, false)
      step.new if step.is_a?(Class)
    end

    def self.mixins = constants.map { |name| const_get(name, false) }.select { |constant| constant.instance_of?(Module) }
  end
end

# All of steps/ loads here, so that a new step is found without the harness having to require it.
Dir[File.join(__dir__, "steps", "*.rb")].sort.each { |file| require file }
