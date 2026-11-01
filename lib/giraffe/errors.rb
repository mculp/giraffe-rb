# frozen_string_literal: true

module Giraffe
  class Error < StandardError; end
  class InvalidOutput < Error; end
  class Parked < Error; end
  class Cancelled < Error; end
end
