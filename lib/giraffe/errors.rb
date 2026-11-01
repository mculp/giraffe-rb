# frozen_string_literal: true

module Giraffe
  class Error < StandardError
    # What a failed model call reported spending, when it got as far as reporting.
    attr_accessor :usage
  end
  class InvalidOutput < Error; end
  class Parked < Error; end
  class Cancelled < Error; end
  class RunLocked < Error; end
end
