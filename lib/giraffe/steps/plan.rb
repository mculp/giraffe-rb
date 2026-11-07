# frozen_string_literal: true

module Giraffe
  module Steps
    # Plans the change from everything learned so far, and keeps the plan only once the coordinator's contracts accept it.
    class Plan
      def call(context)
        @context = context
        context.ask("plan", inputs) { |output| save(output) }
        context.finish
      end

      private

      def inputs
        {"triage" => @context.artifact("triage_brief"), "investigation" => @context.artifact("investigation_report"),
         "reproduction" => @context.artifact("repro_report"), "screen_checks" => @context.run.config["screen_checks"].to_a}
      end

      def save(output)
        @context.run.coordinator.validate_plan!(output["implementation_plan"], output["test_plan"])
        @context.put("implementation_plan", output.fetch("implementation_plan"))
        @context.put("test_plan", output.fetch("test_plan"))
        @context.checkpoint("ui", output.fetch("ui"))
      end
    end
  end
end
