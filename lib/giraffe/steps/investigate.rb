# frozen_string_literal: true

module Giraffe
  module Steps
    # Reads the ticket three ways, each a call of its own that starts from the same triage brief: the ticket itself,
    # prior art for it, and the codebase it will land in.
    class Investigate
      PERSPECTIVES = %w[ticket prior_art codebase].freeze

      def call(context)
        @context = context
        reports = PERSPECTIVES.to_h { |perspective| [perspective, investigate(perspective)] }
        context.put("investigation_report", {"reports" => reports})
        context.finish
      end

      private

      def investigate(perspective)
        @context.ask("investigate", {"perspective" => perspective, "triage" => @context.artifact("triage_brief")}, unit: perspective)
      end
    end
  end
end
